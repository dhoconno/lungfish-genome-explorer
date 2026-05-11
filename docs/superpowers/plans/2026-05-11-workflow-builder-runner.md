# Workflow Builder Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native Swift Workflow Builder system that uses explicit `.lungfishfastq` input nodes, an expanded VSP2 FASTQ operation graph, project workflow management, and a builder-native runner with complete provenance.

**Architecture:** Add concrete Workflow Builder node types and a VSP2 template in `LungfishWorkflow`, then wire AppKit palette/inspector/library UI in `LungfishApp`. The runner stays in `LungfishApp` because it can reuse app-side FASTQ bundle materialization/import helpers, while output provenance is written through existing `LungfishWorkflow` provenance models.

**Tech Stack:** Swift 6.2, AppKit, XCTest, `LungfishWorkflow`, `LungfishApp`, `LungfishIO`, existing native FASTQ recipe/tool infrastructure.

---

## File Structure

- Modify `Sources/LungfishWorkflow/Builder/WorkflowNode.swift`
  Add concrete FASTQ input and VSP2 operation node types, typed ports, parameter definitions, categories, and default labels.
- Modify `Sources/LungfishWorkflow/Builder/WorkflowGraph.swift`
  Add explicit-input validation helpers and selection-safe graph mutations.
- Create `Sources/LungfishWorkflow/Builder/VSP2WorkflowTemplate.swift`
  Build the expanded VSP2 graph from bundled recipe defaults.
- Create `Sources/LungfishWorkflow/Builder/WorkflowBuilderSupportedRunner.swift`
  Validate whether a graph is supported by the first builder-native runner and expose node-to-step mapping metadata.
- Modify `Sources/LungfishWorkflow/Builder/WorkflowBuilderRunRecord.swift`
  Add output bundle records and per-node provenance summaries needed by the expanded runner.
- Modify `Tests/LungfishWorkflowTests/WorkflowBuilderTests.swift`
  Cover node definitions, parameters, explicit input validation, and VSP2 template graph shape.
- Modify `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift`
  Add inspector and workflow library panes, wire selection updates, and route VSP2 template/run actions.
- Modify `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowCanvasView.swift`
  Expose selection state, selected node updates, selected connection deletion state, and dirty-state callbacks.
- Modify `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodePalette.swift`
  Include new FASTQ operation categories and concrete operation nodes.
- Create `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodeInspectorView.swift`
  AppKit inspector for label, explicit FASTQ input bundle selection, and typed operation parameters.
- Create `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowLibraryView.swift`
  AppKit library list and actions for project-local `.lungfishflow` bundles.
- Create `Sources/LungfishApp/Services/WorkflowLibraryStore.swift`
  Filesystem-backed workflow list/open/duplicate/rename/delete support for `<project>/Workflows`.
- Create `Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift`
  Builder-native graph runner for explicit FASTQ bundle inputs and VSP2 operation nodes.
- Create `Sources/LungfishApp/Services/WorkflowBuilderFASTQOutputWriter.swift`
  Writes final derived `.lungfishfastq` bundles and output-level provenance that points at stored payloads.
- Modify `Sources/LungfishApp/Services/WorkflowBuilderRunService.swift`
  Dispatch supported FASTQ builder graphs through `WorkflowBuilderFASTQRunner`; keep existing local workflow fallback for exporter-backed graphs.
- Modify `Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift`
  Cover inspector/library integration and menu/toolbar actions.
- Modify `Tests/LungfishAppTests/WorkflowBuilderRunServiceTests.swift`
  Cover runner dispatch, failure status, output records, and provenance.
- Create `Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift`
  Focused builder-native FASTQ runner tests with stubs.
- Create `Tests/LungfishIntegrationTests/WorkflowBuilderVSP2ParityTests.swift`
  Parity test comparing the expanded builder graph with the existing VSP2 recipe path, skipped when managed tools/databases are unavailable.

---

### Task 1: Add Concrete Workflow Node Types

**Files:**
- Modify: `Sources/LungfishWorkflow/Builder/WorkflowNode.swift`
- Modify: `Sources/LungfishWorkflow/Builder/WorkflowGraph.swift`
- Test: `Tests/LungfishWorkflowTests/WorkflowBuilderTests.swift`

- [ ] **Step 1: Write failing node-definition tests**

Add tests to `WorkflowBuilderTests`:

```swift
func testFastqBundleInputNodeStoresProjectRelativeBundlePath() throws {
    let node = WorkflowNode(
        type: .fastqBundleInput,
        label: "Input sample",
        position: .zero,
        parameters: ["bundle_path": "@/Imports/sample.lungfishfastq"]
    )

    XCTAssertEqual(node.type.displayName, "FASTQ Bundle Input")
    XCTAssertEqual(node.outputPort(withId: "reads")?.dataType, .fastqBundle)
    XCTAssertTrue(node.inputPorts.isEmpty)

    let resolved = try node.resolvedParameters()
    XCTAssertEqual(resolved["bundle_path"], .string("@/Imports/sample.lungfishfastq"))
}

func testVSP2NodeTypesExposeExpectedPortsAndDefaults() throws {
    let expected: [(WorkflowNodeType, String, String)] = [
        (.fastpDedup, "Remove PCR duplicates", "deduplicated"),
        (.fastpTrim, "Adapter + quality trim", "trimmed"),
        (.deaconHumanScrub, "Remove human reads", "scrubbed"),
        (.fastpMerge, "Merge overlapping pairs", "merged"),
        (.seqkitLengthFilter, "Remove short reads", "filtered"),
    ]

    for (type, label, outputPort) in expected {
        let node = WorkflowNode(type: type, position: .zero)
        XCTAssertEqual(node.label, label)
        XCTAssertEqual(node.inputPort(withId: "reads")?.dataType, .fastqBundle)
        XCTAssertEqual(node.outputPort(withId: outputPort)?.dataType, .fastqBundle)
        XCTAssertFalse(node.parameterValidationIssues().contains {
            if case .missing = $0 { return true }
            return false
        })
    }
}

func testExplicitInputValidationRejectsMissingBundlePath() {
    var graph = WorkflowGraph(name: "Missing input")
    _ = graph.addNode(type: .fastqBundleInput, position: .zero)

    let issues = graph.validate()

    XCTAssertTrue(issues.contains {
        if case .missingNodeParameter(_, _, let parameter) = $0 {
            return parameter == "bundle_path"
        }
        return false
    })
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter WorkflowBuilderTests/testFastqBundleInputNodeStoresProjectRelativeBundlePath
swift test --filter WorkflowBuilderTests/testVSP2NodeTypesExposeExpectedPortsAndDefaults
swift test --filter WorkflowBuilderTests/testExplicitInputValidationRejectsMissingBundlePath
```

Expected: compilation fails because the new `WorkflowNodeType` cases do not exist.

- [ ] **Step 3: Add node types, categories, ports, and parameter defaults**

Modify `WorkflowNodeType` in `WorkflowNode.swift`:

```swift
case fastqBundleInput = "fastq_bundle_input"
case fastpDedup = "fastp_dedup"
case fastpTrim = "fastp_trim"
case deaconHumanScrub = "deacon_human_scrub"
case fastpMerge = "fastp_merge"
case seqkitLengthFilter = "seqkit_length_filter"
```

Add display names:

```swift
case .fastqBundleInput: return "FASTQ Bundle Input"
case .fastpDedup: return "Remove PCR duplicates"
case .fastpTrim: return "Adapter + quality trim"
case .deaconHumanScrub: return "Remove human reads"
case .fastpMerge: return "Merge overlapping pairs"
case .seqkitLengthFilter: return "Remove short reads"
```

Add icon names:

```swift
case .fastqBundleInput: return "shippingbox.fill"
case .fastpDedup: return "square.stack.3d.down.right"
case .fastpTrim: return "scissors"
case .deaconHumanScrub: return "person.crop.circle.badge.xmark"
case .fastpMerge: return "arrow.triangle.merge"
case .seqkitLengthFilter: return "line.3.horizontal.decrease.circle"
```

Add categories by extending `NodeCategory`:

```swift
case trimmingFiltering = "Trimming & Filtering"
case decontamination = "Decontamination"
case readProcessing = "Read Processing"
```

Map categories:

```swift
case .fastqBundleInput:
    return .input
case .fastpDedup, .fastpTrim, .seqkitLengthFilter:
    return .trimmingFiltering
case .deaconHumanScrub:
    return .decontamination
case .fastpMerge:
    return .readProcessing
```

Add ports:

```swift
case .fastqBundleInput:
    return []
case .fastpDedup, .fastpTrim, .deaconHumanScrub, .fastpMerge, .seqkitLengthFilter:
    return [NodePort(id: "reads", name: "Reads", dataType: .fastqBundle, direction: .input)]
```

```swift
case .fastqBundleInput:
    return [NodePort(id: "reads", name: "Reads", dataType: .fastqBundle, direction: .output)]
case .fastpDedup:
    return [NodePort(id: "deduplicated", name: "Deduplicated", dataType: .fastqBundle, direction: .output)]
case .fastpTrim:
    return [NodePort(id: "trimmed", name: "Trimmed", dataType: .fastqBundle, direction: .output)]
case .deaconHumanScrub:
    return [NodePort(id: "scrubbed", name: "Scrubbed", dataType: .fastqBundle, direction: .output)]
case .fastpMerge:
    return [NodePort(id: "merged", name: "Merged", dataType: .fastqBundle, direction: .output)]
case .seqkitLengthFilter:
    return [NodePort(id: "filtered", name: "Filtered", dataType: .fastqBundle, direction: .output)]
```

Add parameter definitions:

```swift
case .fastqBundleInput:
    var path = ParameterDefinition(
        name: "bundle_path",
        title: "FASTQ bundle",
        description: "Project-relative path to an existing .lungfishfastq bundle.",
        type: .string,
        defaultValue: nil,
        isRequired: true
    )
    path.pattern = #"^@/.+\.lungfishfastq$"#
    return [path]
case .fastpDedup:
    return []
case .fastpTrim:
    var detectAdapter = ParameterDefinition(name: "detectAdapter", title: "Detect adapters", type: .boolean, defaultValue: .boolean(true))
    var quality = ParameterDefinition(name: "quality", title: "Quality threshold", type: .integer, defaultValue: .integer(15))
    quality.minimum = 0
    quality.maximum = 93
    var window = ParameterDefinition(name: "window", title: "Window size", type: .integer, defaultValue: .integer(5))
    window.minimum = 1
    var cutMode = ParameterDefinition(
        name: "cutMode",
        title: "Cut mode",
        type: .string,
        defaultValue: .string("right"),
        allowedValues: [.string("right"), .string("front"), .string("tail"), .string("both")]
    )
    return [detectAdapter, quality, window, cutMode]
case .deaconHumanScrub:
    return [
        ParameterDefinition(
            name: "database",
            title: "Database",
            type: .string,
            defaultValue: .string("deacon-panhuman"),
            allowedValues: [.string("deacon-panhuman")]
        )
    ]
case .fastpMerge:
    var minOverlap = ParameterDefinition(name: "minOverlap", title: "Minimum overlap", type: .integer, defaultValue: .integer(15))
    minOverlap.minimum = 1
    return [minOverlap]
case .seqkitLengthFilter:
    var minLength = ParameterDefinition(name: "minLength", title: "Minimum length", type: .integer, defaultValue: .integer(50))
    minLength.minimum = 0
    var maxLength = ParameterDefinition(name: "maxLength", title: "Maximum length", type: .integer, defaultValue: nil, isRequired: false)
    maxLength.minimum = 1
    return [minLength, maxLength]
```

- [ ] **Step 4: Update category icon/color switches**

Update `NodeCategory.iconName` in `WorkflowNode.swift`:

```swift
case .trimmingFiltering: return "line.3.horizontal.decrease.circle"
case .decontamination: return "person.crop.circle.badge.xmark"
case .readProcessing: return "arrow.triangle.merge"
```

Update `colorForCategory` in `WorkflowNodeView.swift` and `WorkflowNodePalette.swift`:

```swift
case .trimmingFiltering:
    return NSColor.systemOrange
case .decontamination:
    return NSColor.systemRed
case .readProcessing:
    return NSColor.systemIndigo
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
swift test --filter WorkflowBuilderTests/testFastqBundleInputNodeStoresProjectRelativeBundlePath
swift test --filter WorkflowBuilderTests/testVSP2NodeTypesExposeExpectedPortsAndDefaults
swift test --filter WorkflowBuilderTests/testExplicitInputValidationRejectsMissingBundlePath
```

Expected: all three tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Builder/WorkflowNode.swift Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodeView.swift Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodePalette.swift Tests/LungfishWorkflowTests/WorkflowBuilderTests.swift
git commit -m "feat: add FASTQ workflow builder node types"
```

---

### Task 2: Add VSP2 Exemplar Graph Builder

**Files:**
- Create: `Sources/LungfishWorkflow/Builder/VSP2WorkflowTemplate.swift`
- Modify: `Tests/LungfishWorkflowTests/WorkflowBuilderTests.swift`

- [ ] **Step 1: Write failing template tests**

Add tests:

```swift
func testVSP2TemplateCreatesExpandedConnectedGraph() throws {
    let graph = try VSP2WorkflowTemplate.makeGraph(
        inputBundleRelativePath: "@/Imports/sample.lungfishfastq"
    )

    let executableNodes = try graph.topologicalSort()
    XCTAssertEqual(executableNodes.map(\.type), [
        .fastqBundleInput,
        .fastpDedup,
        .fastpTrim,
        .deaconHumanScrub,
        .fastpMerge,
        .seqkitLengthFilter,
    ])
    XCTAssertEqual(graph.connectionCount, 6)
    XCTAssertEqual(graph.allNodes.first { $0.type == .fastqBundleInput }?.parameters["bundle_path"], "@/Imports/sample.lungfishfastq")
}

func testVSP2TemplateUsesRecipeDefaults() throws {
    let graph = try VSP2WorkflowTemplate.makeGraph(
        inputBundleRelativePath: "@/Imports/sample.lungfishfastq"
    )

    let trim = try XCTUnwrap(graph.allNodes.first { $0.type == .fastpTrim })
    XCTAssertEqual(trim.parameters["detectAdapter"], "true")
    XCTAssertEqual(trim.parameters["quality"], "15")
    XCTAssertEqual(trim.parameters["window"], "5")
    XCTAssertEqual(trim.parameters["cutMode"], "right")

    let scrub = try XCTUnwrap(graph.allNodes.first { $0.type == .deaconHumanScrub })
    XCTAssertEqual(scrub.parameters["database"], "deacon-panhuman")

    let merge = try XCTUnwrap(graph.allNodes.first { $0.type == .fastpMerge })
    XCTAssertEqual(merge.parameters["minOverlap"], "15")

    let length = try XCTUnwrap(graph.allNodes.first { $0.type == .seqkitLengthFilter })
    XCTAssertEqual(length.parameters["minLength"], "50")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter WorkflowBuilderTests/testVSP2TemplateCreatesExpandedConnectedGraph
swift test --filter WorkflowBuilderTests/testVSP2TemplateUsesRecipeDefaults
```

Expected: compilation fails because `VSP2WorkflowTemplate` does not exist.

- [ ] **Step 3: Implement template builder**

Create `VSP2WorkflowTemplate.swift`:

```swift
import CoreGraphics
import Foundation

public enum VSP2WorkflowTemplate {
    public static func makeGraph(
        name: String = "VSP2 FASTQ Workflow",
        inputBundleRelativePath: String? = nil
    ) throws -> WorkflowGraph {
        var graph = WorkflowGraph(
            name: name,
            description: "Expanded VSP2 FASTQ bundle workflow",
            version: WorkflowVersion.defaultVersion
        )

        let input = graph.addNode(
            type: .fastqBundleInput,
            position: CGPoint(x: 120, y: 180),
            label: "FASTQ bundle input"
        )
        try update(&graph, node: input, parameters: inputBundleRelativePath.map { ["bundle_path": $0] } ?? [:])

        let dedup = graph.addNode(type: .fastpDedup, position: CGPoint(x: 360, y: 180))
        let trim = try graph.addStableNode(
            id: UUID(),
            type: .fastpTrim,
            position: CGPoint(x: 600, y: 180),
            parameters: [
                "detectAdapter": "true",
                "quality": "15",
                "window": "5",
                "cutMode": "right",
            ]
        )
        let scrub = try graph.addStableNode(
            id: UUID(),
            type: .deaconHumanScrub,
            position: CGPoint(x: 840, y: 180),
            parameters: ["database": "deacon-panhuman"]
        )
        let merge = try graph.addStableNode(
            id: UUID(),
            type: .fastpMerge,
            position: CGPoint(x: 1080, y: 180),
            parameters: ["minOverlap": "15"]
        )
        let filter = try graph.addStableNode(
            id: UUID(),
            type: .seqkitLengthFilter,
            position: CGPoint(x: 1320, y: 180),
            parameters: ["minLength": "50"]
        )

        try graph.addConnection(sourceNodeId: input.id, sourcePortId: "reads", targetNodeId: dedup.id, targetPortId: "reads")
        try graph.addConnection(sourceNodeId: dedup.id, sourcePortId: "deduplicated", targetNodeId: trim.id, targetPortId: "reads")
        try graph.addConnection(sourceNodeId: trim.id, sourcePortId: "trimmed", targetNodeId: scrub.id, targetPortId: "reads")
        try graph.addConnection(sourceNodeId: scrub.id, sourcePortId: "scrubbed", targetNodeId: merge.id, targetPortId: "reads")
        try graph.addConnection(sourceNodeId: merge.id, sourcePortId: "merged", targetNodeId: filter.id, targetPortId: "reads")
        try graph.addConnection(sourceNodeId: filter.id, sourcePortId: "filtered", targetNodeId: graph.projectOutput.id, targetPortId: "input")

        return graph
    }

    private static func update(
        _ graph: inout WorkflowGraph,
        node: WorkflowNode,
        parameters: [String: String]
    ) throws {
        var updated = node
        updated.parameters = parameters
        try graph.updateNode(updated)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter WorkflowBuilderTests/testVSP2TemplateCreatesExpandedConnectedGraph
swift test --filter WorkflowBuilderTests/testVSP2TemplateUsesRecipeDefaults
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Builder/VSP2WorkflowTemplate.swift Tests/LungfishWorkflowTests/WorkflowBuilderTests.swift
git commit -m "feat: add VSP2 workflow builder template"
```

---

### Task 3: Add Canvas Selection Editing Surface

**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowCanvasView.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift`

- [ ] **Step 1: Write failing canvas editing tests**

Add tests:

```swift
func testCanvasReportsDeletableSelectionState() throws {
    let canvas = WorkflowCanvasView()
    let node = canvas.graph.addNode(type: .fastpTrim, position: .zero)
    canvas.graph = canvas.graph

    XCTAssertFalse(canvas.hasDeletableSelection)
    canvas.selectNode(node.id)
    XCTAssertTrue(canvas.hasDeletableSelection)
    canvas.selectNode(WorkflowGraph.sampleInputAnchorID)
    XCTAssertFalse(canvas.hasDeletableSelection)
}

func testCanvasUpdatesSelectedNodeParameters() throws {
    let canvas = WorkflowCanvasView()
    let node = canvas.graph.addNode(type: .fastpTrim, position: .zero)
    canvas.graph = canvas.graph
    canvas.selectNode(node.id)

    try canvas.updateSelectedNode { selected in
        selected.label = "Trim tuned"
        selected.parameters["quality"] = "20"
    }

    let updated = try XCTUnwrap(canvas.graph.getNode(node.id))
    XCTAssertEqual(updated.label, "Trim tuned")
    XCTAssertEqual(updated.parameters["quality"], "20")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter WorkflowBuilderAppIntegrationTests/testCanvasReportsDeletableSelectionState
swift test --filter WorkflowBuilderAppIntegrationTests/testCanvasUpdatesSelectedNodeParameters
```

Expected: compilation fails because `hasDeletableSelection` and `updateSelectedNode` do not exist.

- [ ] **Step 3: Implement canvas APIs**

Add to `WorkflowCanvasView`:

```swift
public var selectedNodeIDsForTesting: Set<UUID> { selectedNodeIds }
public var selectedConnectionIDsForTesting: Set<UUID> { selectedConnectionIds }

public var hasDeletableSelection: Bool {
    selectedConnectionIds.contains { graph.getConnection($0) != nil }
        || selectedNodeIds.contains { graph.getNode($0)?.isRemovable == true }
}

public func updateSelectedNode(_ mutate: (inout WorkflowNode) throws -> Void) throws {
    guard selectedNodeIds.count == 1,
          let nodeID = selectedNodeIds.first,
          var node = graph.getNode(nodeID) else {
        return
    }
    try mutate(&node)
    try graph.updateNode(node)
    nodeViews[nodeID]?.update(with: node)
    updateNodeViewFrame(nodeViews[nodeID]!, for: node)
    rebuildConnectionViews()
    delegate?.canvasViewDidModifyGraph(self)
    delegate?.canvasView(self, didSelectNode: node)
}
```

Guard the forced unwrap by assigning the view first in the final implementation:

```swift
if let nodeView = nodeViews[nodeID] {
    nodeView.update(with: node)
    updateNodeViewFrame(nodeView, for: node)
}
```

- [ ] **Step 4: Update delete menu validation**

Modify `validateMenuItem` in `WorkflowBuilderViewController`:

```swift
case #selector(performDelete(_:)):
    return canvasViewController.canvasView.hasDeletableSelection
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
swift test --filter WorkflowBuilderAppIntegrationTests/testCanvasReportsDeletableSelectionState
swift test --filter WorkflowBuilderAppIntegrationTests/testCanvasUpdatesSelectedNodeParameters
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/WorkflowBuilder/WorkflowCanvasView.swift Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift
git commit -m "feat: expose workflow canvas node editing"
```

---

### Task 4: Add Node Inspector

**Files:**
- Create: `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodeInspectorView.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift`

- [ ] **Step 1: Write failing inspector tests**

Add tests:

```swift
func testInspectorEditsSelectedNodeLabelAndParameters() throws {
    let inspector = WorkflowNodeInspectorView()
    var node = WorkflowNode(
        type: .fastpTrim,
        position: .zero,
        parameters: ["quality": "15"]
    )
    var captured: WorkflowNode?
    inspector.onNodeChanged = { captured = $0 }

    inspector.inspect(node: node, activeProjectURL: nil)
    inspector.testingSetLabel("Trim strict")
    inspector.testingSetParameter("quality", value: "25")

    node = try XCTUnwrap(captured)
    XCTAssertEqual(node.label, "Trim strict")
    XCTAssertEqual(node.parameters["quality"], "25")
}

func testInspectorRejectsInputBundleOutsideProject() throws {
    let project = URL(fileURLWithPath: "/tmp/Project.lungfish", isDirectory: true)
    let inspector = WorkflowNodeInspectorView()
    inspector.inspect(node: WorkflowNode(type: .fastqBundleInput, position: .zero), activeProjectURL: project)

    XCTAssertThrowsError(try inspector.testingChooseBundle(URL(fileURLWithPath: "/tmp/Other/sample.lungfishfastq", isDirectory: true)))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter WorkflowBuilderAppIntegrationTests/testInspectorEditsSelectedNodeLabelAndParameters
swift test --filter WorkflowBuilderAppIntegrationTests/testInspectorRejectsInputBundleOutsideProject
```

Expected: compilation fails because `WorkflowNodeInspectorView` does not exist.

- [ ] **Step 3: Implement inspector view**

Create `WorkflowNodeInspectorView` with this public surface:

```swift
@MainActor
public final class WorkflowNodeInspectorView: NSView {
    public var onNodeChanged: ((WorkflowNode) -> Void)?

    public func inspect(node: WorkflowNode?, activeProjectURL: URL?) {
        self.node = node
        self.activeProjectURL = activeProjectURL?.standardizedFileURL
        rebuild()
    }

    public func testingSetLabel(_ label: String) {
        guard var node else { return }
        node.label = label
        self.node = node
        onNodeChanged?(node)
    }

    public func testingSetParameter(_ name: String, value: String) {
        guard var node else { return }
        node.parameters[name] = value
        self.node = node
        onNodeChanged?(node)
    }

    public func testingChooseBundle(_ url: URL) throws {
        try setInputBundle(url)
    }
}
```

Build UI with:

- Header label: selected node type or "No selection"
- `NSTextField` for node label
- `NSPathControl` + "Choose..." button for `.fastqBundleInput`
- Parameter rows generated from `node.type.parameterDefinitions`
- Read-only port summary text
- Validation text from `node.parameterValidationIssues()`

Implement project-relative conversion:

```swift
private func projectRelativePath(for url: URL) throws -> String {
    guard let activeProjectURL else {
        throw WorkflowNodeInspectorError.missingProject
    }
    let root = activeProjectURL.standardizedFileURL.path
    let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
    let target = url.standardizedFileURL.path
    guard target.hasPrefix(normalizedRoot) else {
        throw WorkflowNodeInspectorError.bundleOutsideProject
    }
    return "@/" + String(target.dropFirst(normalizedRoot.count))
}
```

- [ ] **Step 4: Integrate inspector in builder split view**

Modify `WorkflowBuilderViewController.configureChildControllers()` to add a trailing inspector split item:

```swift
inspectorViewController = WorkflowNodeInspectorViewController()
inspectorViewController.inspector.onNodeChanged = { [weak self] updated in
    guard let self else { return }
    try? self.canvasViewController.canvasView.updateSelectedNode { node in
        node = updated
    }
}

inspectorItem = NSSplitViewItem(viewController: inspectorViewController)
inspectorItem.minimumThickness = 260
inspectorItem.maximumThickness = 360
inspectorItem.preferredThicknessFraction = 0.25
addSplitViewItem(inspectorItem)
```

Update selection delegate:

```swift
public func canvasView(_ canvasView: WorkflowCanvasView, didSelectNode node: WorkflowNode?) {
    inspectorViewController.inspector.inspect(node: node, activeProjectURL: activeProjectURL)
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter WorkflowBuilderAppIntegrationTests/testInspectorEditsSelectedNodeLabelAndParameters
swift test --filter WorkflowBuilderAppIntegrationTests/testInspectorRejectsInputBundleOutsideProject
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodeInspectorView.swift Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift
git commit -m "feat: add workflow node inspector"
```

---

### Task 5: Add Workflow Library Store and UI

**Files:**
- Create: `Sources/LungfishApp/Services/WorkflowLibraryStore.swift`
- Create: `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowLibraryView.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift`

- [ ] **Step 1: Write failing workflow library tests**

Add tests:

```swift
func testWorkflowLibraryStoreListsDuplicatesRenamesAndDeletesBundles() throws {
    let root = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
    let workflows = root.appendingPathComponent("Workflows", isDirectory: true)
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    let source = workflows.appendingPathComponent("A.lungfishflow", isDirectory: true)

    let controller = WorkflowBuilderViewController()
    controller.loadViewIfNeeded()
    controller.graph = WorkflowGraph(name: "A")
    _ = try controller.saveWorkflowBundleForTesting(to: source)

    let store = WorkflowLibraryStore(projectURL: root)
    XCTAssertEqual(try store.listWorkflows().map(\.name), ["A"])

    let duplicate = try store.duplicate(source, newName: "B")
    XCTAssertEqual(duplicate.lastPathComponent, "B.lungfishflow")

    let renamed = try store.rename(duplicate, newName: "C")
    XCTAssertEqual(renamed.lastPathComponent, "C.lungfishflow")

    try store.delete(renamed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter WorkflowBuilderAppIntegrationTests/testWorkflowLibraryStoreListsDuplicatesRenamesAndDeletesBundles
```

Expected: compilation fails because `WorkflowLibraryStore` does not exist.

- [ ] **Step 3: Implement store**

Create:

```swift
public struct WorkflowLibraryItem: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let version: String
    public let modifiedAt: Date
    public let lastRunStatus: WorkflowBuilderRunStatus?
}

public struct WorkflowLibraryStore: Sendable {
    public let projectURL: URL

    public var workflowsDirectoryURL: URL {
        projectURL.appendingPathComponent("Workflows", isDirectory: true)
    }

    public func listWorkflows() throws -> [WorkflowLibraryItem]
    public func duplicate(_ url: URL, newName: String) throws -> URL
    public func rename(_ url: URL, newName: String) throws -> URL
    public func delete(_ url: URL) throws
}
```

Use `WorkflowGraph` decoding from `graph.json` or `workflow.json`. Use `runs/*/run.json` sorted by modification date to derive `lastRunStatus`.

- [ ] **Step 4: Implement library view**

Create `WorkflowLibraryView` with:

```swift
@MainActor
public final class WorkflowLibraryView: NSView {
    public var onOpenWorkflow: ((URL) -> Void)?
    public var onNewWorkflow: (() -> Void)?
    public var onDuplicateWorkflow: ((URL) -> Void)?
    public var onRenameWorkflow: ((URL) -> Void)?
    public var onDeleteWorkflow: ((URL) -> Void)?

    public func reload(projectURL: URL?)
}
```

Use an `NSTableView` with columns: Name, Version, Modified, Last Run.

- [ ] **Step 5: Integrate library above palette**

Add a left sidebar container that stacks `WorkflowLibraryView` above `WorkflowNodePalette`. When `configureRunContext(projectURL:preferredSampleURL:)` is called, reload the library.

Connect actions:

- New calls `newWorkflow()`
- Open calls `loadWorkflow(from:)`
- Duplicate/Rename/Delete call `WorkflowLibraryStore` then reload

- [ ] **Step 6: Run tests**

Run:

```bash
swift test --filter WorkflowBuilderAppIntegrationTests/testWorkflowLibraryStoreListsDuplicatesRenamesAndDeletesBundles
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Services/WorkflowLibraryStore.swift Sources/LungfishApp/Views/WorkflowBuilder/WorkflowLibraryView.swift Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift
git commit -m "feat: add project workflow library"
```

---

### Task 6: Add FASTQ Builder Runner Graph Compiler

**Files:**
- Create: `Sources/LungfishWorkflow/Builder/WorkflowBuilderSupportedRunner.swift`
- Create: `Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift`

- [ ] **Step 1: Write failing compiler tests**

Create `WorkflowBuilderFASTQRunnerTests.swift`:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class WorkflowBuilderFASTQRunnerTests: XCTestCase {
    func testCompilerRecognizesExpandedVSP2Graph() throws {
        let graph = try VSP2WorkflowTemplate.makeGraph(
            inputBundleRelativePath: "@/Imports/sample.lungfishfastq"
        )

        let plan = try WorkflowBuilderSupportedRunner.compileFASTQPlan(graph)

        XCTAssertEqual(plan.steps.map(\.nodeType), [
            .fastpDedup,
            .fastpTrim,
            .deaconHumanScrub,
            .fastpMerge,
            .seqkitLengthFilter,
        ])
        XCTAssertEqual(plan.inputs.count, 1)
        XCTAssertEqual(plan.inputs.first?.projectRelativePath, "@/Imports/sample.lungfishfastq")
    }

    func testCompilerRejectsUnsupportedBranchingTransformGraph() throws {
        var graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/sample.lungfishfastq")
        let qc = graph.addNode(type: .qualityControl, position: .zero)
        let input = try XCTUnwrap(graph.allNodes.first { $0.type == .fastqBundleInput })
        _ = try graph.addConnection(sourceNodeId: input.id, sourcePortId: "reads", targetNodeId: qc.id, targetPortId: "reads")

        XCTAssertThrowsError(try WorkflowBuilderSupportedRunner.compileFASTQPlan(graph))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter WorkflowBuilderFASTQRunnerTests/testCompilerRecognizesExpandedVSP2Graph
swift test --filter WorkflowBuilderFASTQRunnerTests/testCompilerRejectsUnsupportedBranchingTransformGraph
```

Expected: compilation fails because `WorkflowBuilderSupportedRunner` does not exist.

- [ ] **Step 3: Implement supported runner compiler**

Create in `LungfishWorkflow`:

```swift
public struct WorkflowBuilderFASTQInputPlan: Sendable, Equatable {
    public let nodeID: UUID
    public let projectRelativePath: String
}

public struct WorkflowBuilderFASTQStepPlan: Sendable, Equatable {
    public let nodeID: UUID
    public let nodeType: WorkflowNodeType
    public let label: String
    public let parameters: [String: ParameterValue]
}

public struct WorkflowBuilderFASTQPlan: Sendable, Equatable {
    public let inputs: [WorkflowBuilderFASTQInputPlan]
    public let steps: [WorkflowBuilderFASTQStepPlan]
}

public enum WorkflowBuilderSupportedRunnerError: Error, LocalizedError, Equatable {
    case unsupportedNode(WorkflowNodeType)
    case missingInputBundle(UUID)
    case unsupportedBranching(UUID)
    case missingRequiredConnection(UUID)
}

public enum WorkflowBuilderSupportedRunner {
    public static func compileFASTQPlan(_ graph: WorkflowGraph) throws -> WorkflowBuilderFASTQPlan
}
```

Compiler behavior:

- Exclude pinned anchors except `projectOutput`.
- Require at least one `.fastqBundleInput`.
- Allow only `.fastqBundleInput`, concrete VSP2 operation nodes, and `.projectOutput`.
- Require each transform node to have exactly one incoming connection and no fan-in.
- For this first runner, reject branching from transform outputs except terminal connection to project output.
- Resolve parameters with `node.resolvedParameters()`.

- [ ] **Step 4: Run compiler tests**

Run:

```bash
swift test --filter WorkflowBuilderFASTQRunnerTests/testCompilerRecognizesExpandedVSP2Graph
swift test --filter WorkflowBuilderFASTQRunnerTests/testCompilerRejectsUnsupportedBranchingTransformGraph
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Builder/WorkflowBuilderSupportedRunner.swift Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift
git commit -m "feat: compile supported FASTQ builder graphs"
```

---

### Task 7: Implement FASTQ Builder Runner with Stubbed Step Executor

**Files:**
- Modify: `Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift`

- [ ] **Step 1: Write failing runner orchestration test**

Add:

```swift
func testRunnerExecutesCompiledStepsInOrderAndWritesOutputRecord() async throws {
    let fixture = try makeFixture()
    let graph = try VSP2WorkflowTemplate.makeGraph(
        inputBundleRelativePath: "@/Imports/sample.lungfishfastq"
    )
    let stepper = RecordingFASTQStepExecutor()
    let outputWriter = RecordingFASTQOutputWriter(outputURL: fixture.outputBundleURL)
    let runner = WorkflowBuilderFASTQRunner(stepExecutor: stepper, outputWriter: outputWriter)

    let result = try await runner.run(
        graph: graph,
        workflowBundleURL: fixture.workflowBundleURL,
        projectURL: fixture.projectURL,
        runID: UUID(),
        runDirectoryURL: fixture.runDirectoryURL,
        progress: { _, _ in }
    )

    XCTAssertEqual(stepper.executedNodeTypes, [.fastpDedup, .fastpTrim, .deaconHumanScrub, .fastpMerge, .seqkitLengthFilter])
    XCTAssertEqual(result.outputBundleURLs, [fixture.outputBundleURL])
}
```

Add small test doubles in the test file:

```swift
private final class RecordingFASTQStepExecutor: WorkflowBuilderFASTQStepExecuting {
    var executedNodeTypes: [WorkflowNodeType] = []

    func execute(
        step: WorkflowBuilderFASTQStepPlan,
        input: WorkflowBuilderFASTQIntermediate,
        workspace: URL
    ) async throws -> WorkflowBuilderFASTQIntermediate {
        executedNodeTypes.append(step.nodeType)
        return input
    }
}

private final class RecordingFASTQOutputWriter: WorkflowBuilderFASTQOutputWriting {
    let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func writeOutput(
        finalIntermediate: WorkflowBuilderFASTQIntermediate,
        sourceBundleURL: URL,
        destinationDirectory: URL,
        workflowName: String,
        runID: UUID,
        steps: [WorkflowBuilderFASTQExecutedStep]
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        return outputURL
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter WorkflowBuilderFASTQRunnerTests/testRunnerExecutesCompiledStepsInOrderAndWritesOutputRecord
```

Expected: compilation fails because runner protocols and result types do not exist.

- [ ] **Step 3: Implement runner protocols and orchestration**

Create in `WorkflowBuilderFASTQRunner.swift`:

```swift
public struct WorkflowBuilderFASTQIntermediate: Sendable, Equatable {
    public let r1: URL
    public let r2: URL?
    public let r3: URL?
    public let format: RecipeFileFormat
}

public struct WorkflowBuilderFASTQExecutedStep: Sendable, Equatable {
    public let nodeID: UUID
    public let nodeType: WorkflowNodeType
    public let label: String
    public let toolName: String
    public let toolVersion: String?
    public let command: [String]
    public let exitCode: Int32
    public let wallTime: TimeInterval
    public let stderr: String?
}

public struct WorkflowBuilderFASTQRunResult: Sendable, Equatable {
    public let outputBundleURLs: [URL]
    public let executedSteps: [WorkflowBuilderFASTQExecutedStep]
}

public protocol WorkflowBuilderFASTQStepExecuting: AnyObject {
    func execute(
        step: WorkflowBuilderFASTQStepPlan,
        input: WorkflowBuilderFASTQIntermediate,
        workspace: URL
    ) async throws -> WorkflowBuilderFASTQIntermediate
}

public protocol WorkflowBuilderFASTQOutputWriting: AnyObject {
    func writeOutput(
        finalIntermediate: WorkflowBuilderFASTQIntermediate,
        sourceBundleURL: URL,
        destinationDirectory: URL,
        workflowName: String,
        runID: UUID,
        steps: [WorkflowBuilderFASTQExecutedStep]
    ) async throws -> URL
}
```

Implement `WorkflowBuilderFASTQRunner.run(...)`:

- Compile graph with `WorkflowBuilderSupportedRunner.compileFASTQPlan`.
- Resolve `@/` input paths against `projectURL`.
- Create a run workspace under `runDirectoryURL/workspace`.
- Use `FASTQCLIMaterializer` or a test-injected materializer to produce initial FASTQ input.
- Execute plan steps in order.
- Write output bundle through injected writer.
- Return output bundle URLs and executed step summaries.

- [ ] **Step 4: Run orchestration test**

Run:

```bash
swift test --filter WorkflowBuilderFASTQRunnerTests/testRunnerExecutesCompiledStepsInOrderAndWritesOutputRecord
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift
git commit -m "feat: orchestrate FASTQ workflow builder runs"
```

---

### Task 8: Implement Real VSP2 Step Executor

**Files:**
- Modify: `Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift`

- [ ] **Step 1: Write failing mapping tests**

Add tests that do not invoke real tools:

```swift
func testStepExecutorMapsNodesToRecipeSteps() throws {
    XCTAssertEqual(WorkflowBuilderFASTQRecipeStepMapper.recipeStep(for: .fastpDedup, parameters: [:]).type, "fastp-dedup")
    XCTAssertEqual(WorkflowBuilderFASTQRecipeStepMapper.recipeStep(for: .fastpTrim, parameters: [
        "detectAdapter": .boolean(true),
        "quality": .integer(15),
        "window": .integer(5),
        "cutMode": .string("right"),
    ]).type, "fastp-trim")
    XCTAssertEqual(WorkflowBuilderFASTQRecipeStepMapper.recipeStep(for: .deaconHumanScrub, parameters: [
        "database": .string("deacon-panhuman"),
    ]).type, "deacon-scrub")
    XCTAssertEqual(WorkflowBuilderFASTQRecipeStepMapper.recipeStep(for: .fastpMerge, parameters: [
        "minOverlap": .integer(15),
    ]).type, "fastp-merge")
    XCTAssertEqual(WorkflowBuilderFASTQRecipeStepMapper.recipeStep(for: .seqkitLengthFilter, parameters: [
        "minLength": .integer(50),
    ]).type, "seqkit-length-filter")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter WorkflowBuilderFASTQRunnerTests/testStepExecutorMapsNodesToRecipeSteps
```

Expected: compilation fails because `WorkflowBuilderFASTQRecipeStepMapper` does not exist.

- [ ] **Step 3: Implement mapper**

Add:

```swift
enum WorkflowBuilderFASTQRecipeStepMapper {
    static func recipeStep(
        for nodeType: WorkflowNodeType,
        parameters: [String: ParameterValue]
    ) -> RecipeStep {
        switch nodeType {
        case .fastpDedup:
            return RecipeStep(type: "fastp-dedup", label: "Remove PCR duplicates", params: nil)
        case .fastpTrim:
            return RecipeStep(type: "fastp-trim", label: "Adapter + quality trim", params: [
                "detectAdapter": .bool(parameters["detectAdapter"]?.boolValue ?? true),
                "quality": .int(parameters["quality"]?.integerValue ?? 15),
                "window": .int(parameters["window"]?.integerValue ?? 5),
                "cutMode": .string(parameters["cutMode"]?.stringValue ?? "right"),
            ])
        case .deaconHumanScrub:
            return RecipeStep(type: "deacon-scrub", label: "Remove human reads", params: [
                "database": .string(parameters["database"]?.stringValue ?? "deacon-panhuman"),
            ])
        case .fastpMerge:
            return RecipeStep(type: "fastp-merge", label: "Merge overlapping pairs", params: [
                "minOverlap": .int(parameters["minOverlap"]?.integerValue ?? 15),
            ])
        case .seqkitLengthFilter:
            var params: [String: AnyCodableValue] = [
                "minLength": .int(parameters["minLength"]?.integerValue ?? 50),
            ]
            if let maxLength = parameters["maxLength"]?.integerValue {
                params["maxLength"] = .int(maxLength)
            }
            return RecipeStep(type: "seqkit-length-filter", label: "Remove short reads", params: params)
        default:
            preconditionFailure("Unsupported FASTQ recipe node type: \(nodeType)")
        }
    }
}
```

- [ ] **Step 4: Implement real executor through single-step RecipeEngine**

Add `RecipeBackedWorkflowBuilderFASTQStepExecutor`:

```swift
final class RecipeBackedWorkflowBuilderFASTQStepExecutor: WorkflowBuilderFASTQStepExecuting {
    private let runner: NativeToolRunner

    init(runner: NativeToolRunner = .shared) {
        self.runner = runner
    }

    func execute(
        step: WorkflowBuilderFASTQStepPlan,
        input: WorkflowBuilderFASTQIntermediate,
        workspace: URL
    ) async throws -> WorkflowBuilderFASTQIntermediate {
        let recipeStep = WorkflowBuilderFASTQRecipeStepMapper.recipeStep(
            for: step.nodeType,
            parameters: step.parameters
        )
        let recipe = Recipe(
            id: "workflow-builder-\(step.nodeType.rawValue)",
            name: step.label,
            requiredInput: .any,
            steps: [recipeStep]
        )
        let context = StepContext(
            workspace: workspace.appendingPathComponent(step.nodeID.uuidString, isDirectory: true),
            threads: max(1, ProcessInfo.processInfo.activeProcessorCount),
            sampleName: step.label.replacingOccurrences(of: " ", with: "-"),
            runner: runner,
            progress: { _, _ in }
        )
        try FileManager.default.createDirectory(at: context.workspace, withIntermediateDirectories: true)
        let result = try await RecipeEngine().execute(
            recipe: recipe,
            input: StepInput(r1: input.r1, r2: input.r2, r3: input.r3, format: input.format),
            context: context
        )
        return WorkflowBuilderFASTQIntermediate(
            r1: result.output.r1,
            r2: result.output.r2,
            r3: result.output.r3,
            format: result.output.format
        )
    }
}
```

Record `RecipeStepResult` data into `WorkflowBuilderFASTQExecutedStep` after each call. If the single-step execution inserts format conversion, keep conversion commands in workflow-run provenance as internal steps but do not create extra canvas node statuses.

- [ ] **Step 5: Run mapping tests**

Run:

```bash
swift test --filter WorkflowBuilderFASTQRunnerTests/testStepExecutorMapsNodesToRecipeSteps
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift
git commit -m "feat: execute FASTQ builder nodes with recipe steps"
```

---

### Task 9: Write Derived FASTQ Output Bundles and Provenance

**Files:**
- Create: `Sources/LungfishApp/Services/WorkflowBuilderFASTQOutputWriter.swift`
- Modify: `Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift`

- [ ] **Step 1: Write failing output writer test**

Add:

```swift
func testOutputWriterCreatesBundleWithFinalPayloadProvenance() async throws {
    let fixture = try makeFixture()
    let finalFASTQ = fixture.root.appendingPathComponent("final.fastq")
    try "@r1\nACGT\n+\nIIII\n".write(to: finalFASTQ, atomically: true, encoding: .utf8)

    let writer = WorkflowBuilderFASTQOutputWriter()
    let output = try await writer.writeOutput(
        finalIntermediate: WorkflowBuilderFASTQIntermediate(r1: finalFASTQ, r2: nil, r3: nil, format: .single),
        sourceBundleURL: fixture.inputBundleURL,
        destinationDirectory: fixture.projectURL.appendingPathComponent("Imports", isDirectory: true),
        workflowName: "VSP2 FASTQ Workflow",
        runID: UUID(uuidString: "00000000-0000-4000-8000-000000000111")!,
        steps: [
            WorkflowBuilderFASTQExecutedStep(
                nodeID: UUID(uuidString: "00000000-0000-4000-8000-000000000112")!,
                nodeType: .seqkitLengthFilter,
                label: "Remove short reads",
                toolName: "seqkit",
                toolVersion: "test",
                command: ["seqkit", "seq", "-m", "50", finalFASTQ.path],
                exitCode: 0,
                wallTime: 0.1,
                stderr: nil
            )
        ]
    )

    XCTAssertEqual(output.pathExtension, "lungfishfastq")
    let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: output))
    let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: output))
    XCTAssertTrue(provenance.steps.contains { step in
        step.outputs.contains { $0.path == payload.standardizedFileURL.path }
    })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter WorkflowBuilderFASTQRunnerTests/testOutputWriterCreatesBundleWithFinalPayloadProvenance
```

Expected: compilation fails because `WorkflowBuilderFASTQOutputWriter` does not exist.

- [ ] **Step 3: Implement output writer**

Create `WorkflowBuilderFASTQOutputWriter`:

- Allocate unique bundle URL under destination directory.
- Copy or ingest final FASTQ payload into the bundle.
- Save `PersistedFASTQMetadata` with ingestion mode from final format.
- Save `FASTQDerivedBundleManifest` with parent/root relative paths, lineage entries for executed steps, payload checksum, and materialized state.
- Write `.lungfish-provenance.json` through `ProvenanceRecorder`.

Use this command shape for the final GUI reproducibility step:

```swift
[
    "Lungfish",
    "Tools > Workflow Builder",
    "run",
    workflowName,
    "--run-id",
    runID.uuidString
]
```

For each executed node, write a `StepExecution` whose output is the final stored payload for terminal provenance if the node produced the terminal payload. Intermediate temporary outputs can appear as step outputs in run-level provenance, but output bundle provenance must include at least one step output path equal to the final payload path.

- [ ] **Step 4: Run output writer test**

Run:

```bash
swift test --filter WorkflowBuilderFASTQRunnerTests/testOutputWriterCreatesBundleWithFinalPayloadProvenance
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/WorkflowBuilderFASTQOutputWriter.swift Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift Tests/LungfishAppTests/WorkflowBuilderFASTQRunnerTests.swift
git commit -m "feat: write FASTQ builder outputs with provenance"
```

---

### Task 10: Integrate FASTQ Runner into WorkflowBuilderRunService

**Files:**
- Modify: `Sources/LungfishApp/Services/WorkflowBuilderRunService.swift`
- Modify: `Sources/LungfishWorkflow/Builder/WorkflowBuilderRunRecord.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderRunServiceTests.swift`

- [ ] **Step 1: Write failing run service dispatch test**

Add:

```swift
func testRunServiceDispatchesSupportedFastqBuilderGraphAndRecordsOutputs() async throws {
    let fixture = try makeFixture()
    let graph = try VSP2WorkflowTemplate.makeGraph(
        inputBundleRelativePath: "@/Imports/A.lungfishfastq"
    )
    let operationCenter = OperationCenter()
    let fastqRunner = StubWorkflowBuilderFASTQRunner(outputBundleURL: fixture.projectURL.appendingPathComponent("Imports/A-vsp2.lungfishfastq", isDirectory: true))
    let service = WorkflowBuilderRunService(operationCenter: operationCenter, fastqRunner: fastqRunner)
    let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

    let result = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)

    let record = try WorkflowBuilderRunStore.readRun(runID: result.runID, from: fixture.workflowBundleURL)
    XCTAssertEqual(record.status, .succeeded)
    XCTAssertTrue(record.provenance.outputs.contains { $0.path.hasSuffix("A-vsp2.lungfishfastq") })
    XCTAssertEqual(fastqRunner.runCount, 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter WorkflowBuilderRunServiceTests/testRunServiceDispatchesSupportedFastqBuilderGraphAndRecordsOutputs
```

Expected: compilation fails because `WorkflowBuilderRunService` does not accept `fastqRunner`.

- [ ] **Step 3: Add runner injection and dispatch**

Add a protocol:

```swift
@MainActor
protocol WorkflowBuilderFASTQRunning {
    func run(
        graph: WorkflowGraph,
        workflowBundleURL: URL,
        projectURL: URL,
        runID: UUID,
        runDirectoryURL: URL,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws -> WorkflowBuilderFASTQRunResult
}
```

Make `WorkflowBuilderFASTQRunner` conform.

Update `WorkflowBuilderRunService` initializer:

```swift
public init(
    operationCenter: OperationCenter = .shared,
    fastqRunner: (any WorkflowBuilderFASTQRunning)? = nil
) {
    self.operationCenter = operationCenter
    self.fastqRunner = fastqRunner ?? WorkflowBuilderFASTQRunner()
    self.executionMode = .graph(Self.makeDefaultGraphExecutor(...))
}
```

Before local workflow export, try:

```swift
if WorkflowBuilderSupportedRunner.canCompileFASTQPlan(graph) {
    let fastqResult = try await fastqRunner.run(
        graph: graph,
        workflowBundleURL: workflowBundleURL,
        projectURL: URL(fileURLWithPath: binding.project.path),
        runID: runID,
        runDirectoryURL: runDirectoryURL,
        progress: { progress, detail in
            self.operationCenter.update(id: parentOperationID, progress: progress, detail: detail)
        }
    )
    additionalOutputs.append(contentsOf: fastqResult.outputBundleURLs.map { LocalWorkflowInputBinding(url: $0, role: .output) })
    mark all sorted nodes succeeded
} else {
    existing local workflow graph executor path
}
```

Keep unsupported scientific graphs failing instead of marking success.

- [ ] **Step 4: Run dispatch test**

Run:

```bash
swift test --filter WorkflowBuilderRunServiceTests/testRunServiceDispatchesSupportedFastqBuilderGraphAndRecordsOutputs
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/WorkflowBuilderRunService.swift Sources/LungfishWorkflow/Builder/WorkflowBuilderRunRecord.swift Tests/LungfishAppTests/WorkflowBuilderRunServiceTests.swift
git commit -m "feat: run supported FASTQ builder graphs"
```

---

### Task 11: Add Toolbar/Menu Action for VSP2 Template

**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift`
- Test: `Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift`

- [ ] **Step 1: Write failing toolbar test**

Add:

```swift
func testWorkflowBuilderToolbarIncludesVSP2TemplateButton() throws {
    let controller = WorkflowBuilderViewController()
    controller.loadViewIfNeeded()
    let toolbar = NSToolbar(identifier: "WorkflowBuilderToolbar")

    XCTAssertTrue(controller.toolbarDefaultItemIdentifiers(toolbar).contains(.workflowAddVSP2Template))

    let item = try XCTUnwrap(
        controller.toolbar(toolbar, itemForItemIdentifier: .workflowAddVSP2Template, willBeInsertedIntoToolbar: true)
    )
    XCTAssertEqual(item.label, "VSP2")
    XCTAssertEqual(item.action, #selector(WorkflowBuilderViewController.addVSP2Workflow(_:)))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter WorkflowBuilderAppIntegrationTests/testWorkflowBuilderToolbarIncludesVSP2TemplateButton
```

Expected: compilation fails because the toolbar identifier/action do not exist.

- [ ] **Step 3: Implement action**

Add toolbar identifier:

```swift
static let workflowAddVSP2Template = NSToolbarItem.Identifier("workflowAddVSP2Template")
```

Add item after `.workflowRun`:

```swift
case .workflowAddVSP2Template:
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = "VSP2"
    item.paletteLabel = "Add VSP2 FASTQ Workflow"
    item.toolTip = "Insert the expanded VSP2 FASTQ workflow"
    item.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Add VSP2 FASTQ Workflow")
    item.target = self
    item.action = #selector(addVSP2Workflow(_:))
    return item
```

Add action:

```swift
@objc public func addVSP2Workflow(_ sender: Any?) {
    do {
        graph = try VSP2WorkflowTemplate.makeGraph()
        hasUnsavedChanges = true
        updateWindowTitle()
        canvasViewController.canvasView.centerContent()
    } catch {
        let alert = NSAlert()
        alert.messageText = "Could Not Add VSP2 Workflow"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        presentAlert(alert)
    }
}
```

- [ ] **Step 4: Run toolbar test**

Run:

```bash
swift test --filter WorkflowBuilderAppIntegrationTests/testWorkflowBuilderToolbarIncludesVSP2TemplateButton
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift Tests/LungfishAppTests/WorkflowBuilderAppIntegrationTests.swift
git commit -m "feat: add VSP2 workflow builder action"
```

---

### Task 12: Add VSP2 Parity Integration Test

**Files:**
- Create: `Tests/LungfishIntegrationTests/WorkflowBuilderVSP2ParityTests.swift`

- [ ] **Step 1: Write parity test**

Create:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
import LungfishIO

final class WorkflowBuilderVSP2ParityTests: XCTestCase {
    func testBuilderVSP2GraphMatchesRecipeEngineOutput() async throws {
        try await requireManagedTools([.fastp, .deacon, .reformat, .seqkit])
        try await requireManagedDatabase("deacon-panhuman")

        let fixture = try await VSP2ParityFixture.make()
        let recipeOutput = try await fixture.runRecipeOracle()
        let builderOutput = try await fixture.runBuilderGraph()

        let recipeRecords = try await normalizedFASTQRecords(in: recipeOutput)
        let builderRecords = try await normalizedFASTQRecords(in: builderOutput)

        XCTAssertEqual(builderRecords, recipeRecords)
        XCTAssertEqual(FASTQMetadataStore.load(for: try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: builderOutput)))?.ingestion?.recipeApplied?.stepResults.map(\.stepName),
                       ["Remove PCR duplicates", "Adapter + quality trim", "Remove human reads", "Merge overlapping pairs", "Remove short reads"])

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: builderOutput))
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: builderOutput))
        XCTAssertTrue(provenance.steps.contains { step in
            step.outputs.contains { $0.path == payload.standardizedFileURL.path }
        })
    }
}
```

Implement helpers in the same file:

- `requireManagedTools(_:)` skips if tools are unavailable.
- `requireManagedDatabase(_:)` skips if database is unavailable.
- `VSP2ParityFixture.make()` creates paired FASTQ input, imports it into `.lungfishfastq` without VSP2, runs VSP2 recipe oracle, and runs builder graph.
- `normalizedFASTQRecords(in:)` materializes a bundle with `FASTQCLIMaterializer`, reads FASTQ records, and sorts by read ID.

- [ ] **Step 2: Run parity test to verify it fails or skips for real reasons**

Run:

```bash
swift test --filter WorkflowBuilderVSP2ParityTests/testBuilderVSP2GraphMatchesRecipeEngineOutput
```

Expected before final runner fixes: fail with a concrete output mismatch, missing provenance, or skip due unavailable tools/database. It must not fail from compilation errors.

- [ ] **Step 3: Add parity-stabilizing implementation checks**

Add focused assertions or helper tests beside the parity test before changing production code:

```swift
func testBuilderRunnerDetectsPairedBundleInputForVSP2() async throws {
    let fixture = try await VSP2ParityFixture.makeImportedInputOnly(pairing: .pairedEnd)
    let detected = try await fixture.detectBuilderInputIntermediate()

    XCTAssertEqual(detected.format, .pairedR1R2)
    XCTAssertNotNil(detected.r2)
}

func testBuilderOutputMetadataPreservesTerminalFormat() async throws {
    let fixture = try await VSP2ParityFixture.makeImportedInputOnly(pairing: .pairedEnd)
    let builderOutput = try await fixture.runBuilderGraph()
    let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: builderOutput))
    let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: payload))

    XCTAssertEqual(metadata.ingestion?.pairingMode, .singleEnd)
    XCTAssertEqual(metadata.ingestion?.recipeApplied?.stepResults.map(\.stepName), [
        "Remove PCR duplicates",
        "Adapter + quality trim",
        "Remove human reads",
        "Merge overlapping pairs",
        "Remove short reads",
    ])
}
```

If either assertion fails, update these concrete production paths:

```swift
// WorkflowBuilderFASTQRunner.resolveInputIntermediate(...)
// 1. Prefer FASTQBundle.pairedFASTQURLs(forDerivedBundle:) for paired inputs.
// 2. Fall back to FASTQCLIMaterializer for interleaved or virtual inputs.
// 3. Surface unsupported classified/mixed inputs as validation errors before tool execution.

// WorkflowBuilderFASTQOutputWriter.writeOutput(...)
// 1. Store merged VSP2 output as single-end FASTQ metadata.
// 2. Persist recipeApplied.stepResults from executed builder nodes in canvas order.
// 3. Rehydrate the terminal node provenance output path to the final stored bundle payload.
```

- [ ] **Step 4: Run parity test again**

Run:

```bash
swift test --filter WorkflowBuilderVSP2ParityTests/testBuilderVSP2GraphMatchesRecipeEngineOutput
```

Expected: pass when managed tools/database exist, otherwise skip with a clear `XCTSkip`.

- [ ] **Step 5: Commit**

```bash
git add Tests/LungfishIntegrationTests/WorkflowBuilderVSP2ParityTests.swift Sources/LungfishApp/Services/WorkflowBuilderFASTQRunner.swift Sources/LungfishApp/Services/WorkflowBuilderFASTQOutputWriter.swift
git commit -m "test: compare builder VSP2 workflow with recipe oracle"
```

---

### Task 13: Update User Manual Workflow Builder Chapter

**Files:**
- Modify: `docs/user-manual/chapters/08-workflows/01-the-workflow-builder.md`

- [ ] **Step 1: Update the documented first workflow**

Revise the procedure so the initial supported exemplar is:

```text
FASTQ Bundle Input
  -> Remove PCR duplicates
  -> Adapter + quality trim
  -> Remove human reads
  -> Merge overlapping pairs
  -> Remove short reads
  -> Project output
```

State that the user selects existing `.lungfishfastq` input bundles in the builder.

- [ ] **Step 2: Check docs for stale claims**

Run:

```bash
rg -n "raw FASTQ|Import FASTQ|Download reference|SARS-CoV-2 reads to variants|right-hand inspector" docs/user-manual/chapters/08-workflows/01-the-workflow-builder.md
```

Expected: no stale "first supported example" language contradicts the explicit `.lungfishfastq` VSP2 exemplar. General future-looking documentation can remain if it is clearly marked as broader builder functionality.

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/chapters/08-workflows/01-the-workflow-builder.md
git commit -m "docs: document VSP2 workflow builder exemplar"
```

---

### Task 14: Final Verification

**Files:**
- No planned file edits

- [ ] **Step 1: Run focused unit and app tests**

Run:

```bash
swift test --filter WorkflowBuilderTests
swift test --filter WorkflowBuilderAppIntegrationTests
swift test --filter WorkflowBuilderRunServiceTests
swift test --filter WorkflowBuilderFASTQRunnerTests
```

Expected: all pass.

- [ ] **Step 2: Run parity integration test**

Run:

```bash
swift test --filter WorkflowBuilderVSP2ParityTests/testBuilderVSP2GraphMatchesRecipeEngineOutput
```

Expected: pass when tools/databases are installed; otherwise skip with an explicit unavailable dependency message.

- [ ] **Step 3: Run related CLI regression tests**

Run:

```bash
swift test --filter ImportFastqCommandTests
swift test --filter FASTQBatchImporterRecipeIntegrationTests
```

Expected: pass or tool-gated integration tests skip for existing dependency reasons.

- [ ] **Step 4: Run build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 5: Inspect provenance artifacts from a successful local run**

For a successful non-skipped run, inspect:

```bash
find /tmp -path '*lungfishflow/runs/*/provenance.json' -print | tail -5
find /tmp -path '*.lungfishfastq/.lungfish-provenance.json' -print | tail -5
```

Expected: the workflow run and derived output bundle both contain provenance. The output bundle provenance references the final stored FASTQ payload path inside the `.lungfishfastq` bundle.

- [ ] **Step 6: Commit final fixes**

If final verification required additional fixes:

```bash
git add <changed-files>
git commit -m "fix: stabilize workflow builder runner verification"
```

If no fixes were needed, do not create an empty commit.
