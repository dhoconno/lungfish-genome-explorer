# Role: Visual Workflow Builder

## Responsibilities

### Primary Duties
- Design node-based visual workflow editor
- Build data flow visualization system
- Implement Nextflow DSL2 code generation
- Implement Snakemake rule generation
- Create workflow validation engine

### Key Deliverables
- Native macOS graph canvas (not web-based)
- Drag-and-drop node palette
- Connection routing with data type validation
- Workflow export to Nextflow/Snakemake
- Visual debugging and execution monitoring

### Decision Authority
- Canvas interaction design
- Node representation format
- Code generation strategy
- Validation rule system

---

## Technical Scope

### Technologies/Frameworks Owned
- Graph data structures
- Constraint-based layout algorithms
- Code generation templates
- Data flow analysis

### Component Ownership
```
LungfishWorkflow/
├── VisualBuilder/
│   ├── Graph/
│   │   ├── WorkflowGraph.swift       # PRIMARY OWNER
│   │   ├── WorkflowNode.swift        # PRIMARY OWNER
│   │   ├── WorkflowEdge.swift        # PRIMARY OWNER
│   │   └── GraphValidator.swift      # PRIMARY OWNER
│   ├── Canvas/
│   │   ├── WorkflowCanvas.swift      # PRIMARY OWNER
│   │   ├── NodeView.swift            # PRIMARY OWNER
│   │   ├── EdgeView.swift            # PRIMARY OWNER
│   │   └── CanvasController.swift    # PRIMARY OWNER
│   ├── Export/
│   │   ├── NextflowExporter.swift    # PRIMARY OWNER
│   │   ├── SnakemakeExporter.swift   # PRIMARY OWNER
│   │   └── CodeGenerator.swift       # PRIMARY OWNER
│   └── Palette/
│       ├── NodePalette.swift         # PRIMARY OWNER
│       └── NodeTemplates.swift       # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── WorkflowBuilder/
│   │   ├── WorkflowBuilderView.swift # PRIMARY OWNER
│   │   ├── NodeInspector.swift       # PRIMARY OWNER
│   │   └── WorkflowPreview.swift     # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Workflow Integration Lead | Execution of built workflows |
| Plugin Architect | Plugin operations as nodes |
| UI/UX Lead | Canvas interaction patterns |
| Swift Architecture Lead | Graph data model |

---

## Key Decisions to Make

### Architectural Choices

1. **Canvas Framework**
   - Custom NSView vs. SpriteKit vs. SceneKit
   - Recommendation: Custom NSView with Core Animation

2. **Graph Layout**
   - Manual placement vs. auto-layout vs. hybrid
   - Recommendation: Hybrid with suggested layout

3. **Code Generation**
   - Template-based vs. AST-based
   - Recommendation: Template-based for readability

4. **Validation**
   - Real-time vs. on-demand vs. both
   - Recommendation: Real-time with visual feedback

### Workflow Node Types
```swift
public enum WorkflowNodeType: String, Codable, CaseIterable {
    // Input/Output
    case fileInput = "file_input"
    case fileOutput = "file_output"
    case folderInput = "folder_input"

    // Processing
    case process = "process"
    case script = "script"

    // Flow control
    case conditional = "conditional"
    case parallel = "parallel"
    case collect = "collect"
    case flatten = "flatten"

    // Data manipulation
    case map = "map"
    case filter = "filter"
    case groupBy = "group_by"

    // Built-in operations
    case fastqc = "fastqc"
    case trim = "trim"
    case align = "align"
    case assembly = "assembly"
    case annotation = "annotation"

    var category: NodeCategory {
        switch self {
        case .fileInput, .fileOutput, .folderInput:
            return .io
        case .process, .script:
            return .processing
        case .conditional, .parallel, .collect, .flatten:
            return .flowControl
        case .map, .filter, .groupBy:
            return .dataManipulation
        case .fastqc, .trim, .align, .assembly, .annotation:
            return .bioinformatics
        }
    }

    var sfSymbol: String {
        switch self {
        case .fileInput: return "doc.fill"
        case .fileOutput: return "doc.badge.arrow.up"
        case .folderInput: return "folder.fill"
        case .process: return "gearshape"
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .conditional: return "arrow.triangle.branch"
        case .parallel: return "arrow.triangle.swap"
        case .collect: return "rectangle.stack"
        case .flatten: return "rectangle.expand.vertical"
        case .map: return "arrow.right.arrow.left"
        case .filter: return "line.3.horizontal.decrease"
        case .groupBy: return "rectangle.3.group"
        case .fastqc: return "checkmark.circle"
        case .trim: return "scissors"
        case .align: return "arrow.left.and.right"
        case .assembly: return "square.grid.3x3"
        case .annotation: return "tag"
        }
    }
}
```

---

## Success Criteria

### Performance Targets
- Canvas render: 60 fps with 100+ nodes
- Node drag latency: < 16ms
- Code generation: < 1 second
- Validation: < 100ms

### Quality Metrics
- Generated code compiles without errors
- Round-trip fidelity (export/import)
- Intuitive node connections (< 3 clicks)
- Visual feedback for all errors

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 5 | Graph data model | Week 11 |
| 5 | Canvas component | Week 12 |
| 5 | Node palette | Week 13 |
| 6 | Nextflow exporter | Week 14 |
| 6 | Snakemake exporter | Week 15 |
| 6 | Workflow validation | Week 16 |

---

## Reference Materials

### Design Patterns
- Node-based editors (Blender, Unreal, Logic Pro)
- Data flow programming
- Visual programming languages

### Workflow Languages
- [Nextflow DSL2](https://www.nextflow.io/docs/latest/dsl2.html)
- [Snakemake Rules](https://snakemake.readthedocs.io/en/stable/snakefiles/rules.html)

### Apple Frameworks
- [Core Animation](https://developer.apple.com/documentation/quartzcore)
- [AppKit Drawing](https://developer.apple.com/documentation/appkit/drawing)

---

## Technical Specifications

### Workflow Graph Model
```swift
public class WorkflowGraph: ObservableObject {
    @Published public var nodes: [WorkflowNode] = []
    @Published public var edges: [WorkflowEdge] = []
    @Published public var metadata: WorkflowMetadata

    public struct WorkflowMetadata: Codable {
        public var name: String
        public var description: String
        public var version: String
        public var author: String
        public var containers: [String: String]  // name -> image
    }

    // Node management
    public func addNode(_ node: WorkflowNode) {
        nodes.append(node)
    }

    public func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.sourceNodeId == id || $0.targetNodeId == id }
    }

    // Edge management
    public func connect(
        from sourceNode: UUID,
        output: String,
        to targetNode: UUID,
        input: String
    ) throws {
        // Validate connection
        guard let source = nodes.first(where: { $0.id == sourceNode }),
              let target = nodes.first(where: { $0.id == targetNode }) else {
            throw GraphError.nodeNotFound
        }

        guard let sourcePort = source.outputs.first(where: { $0.name == output }),
              let targetPort = target.inputs.first(where: { $0.name == input }) else {
            throw GraphError.portNotFound
        }

        // Type compatibility check
        guard sourcePort.dataType.isCompatible(with: targetPort.dataType) else {
            throw GraphError.incompatibleTypes(sourcePort.dataType, targetPort.dataType)
        }

        // Check for cycles
        if wouldCreateCycle(from: sourceNode, to: targetNode) {
            throw GraphError.cycleDetected
        }

        let edge = WorkflowEdge(
            sourceNodeId: sourceNode,
            sourcePort: output,
            targetNodeId: targetNode,
            targetPort: input
        )

        edges.append(edge)
    }

    // Validation
    public func validate() -> [ValidationError] {
        var errors: [ValidationError] = []

        // Check for unconnected required inputs
        for node in nodes {
            for input in node.inputs where input.required {
                let hasConnection = edges.contains {
                    $0.targetNodeId == node.id && $0.targetPort == input.name
                }
                if !hasConnection {
                    errors.append(.unconnectedInput(node: node.id, port: input.name))
                }
            }
        }

        // Check for orphan nodes
        for node in nodes {
            let hasInput = edges.contains { $0.targetNodeId == node.id }
            let hasOutput = edges.contains { $0.sourceNodeId == node.id }
            let isInputNode = node.type == .fileInput || node.type == .folderInput
            let isOutputNode = node.type == .fileOutput

            if !isInputNode && !hasInput {
                errors.append(.orphanNode(node: node.id))
            }
            if !isOutputNode && !hasOutput {
                errors.append(.deadEndNode(node: node.id))
            }
        }

        return errors
    }

    // Topological sort
    public func executionOrder() throws -> [WorkflowNode] {
        var sorted: [WorkflowNode] = []
        var visited: Set<UUID> = []
        var visiting: Set<UUID> = []

        func visit(_ node: WorkflowNode) throws {
            if visiting.contains(node.id) {
                throw GraphError.cycleDetected
            }
            if visited.contains(node.id) {
                return
            }

            visiting.insert(node.id)

            // Visit all dependencies first
            let dependencies = edges.filter { $0.targetNodeId == node.id }
                .compactMap { edge in nodes.first { $0.id == edge.sourceNodeId } }

            for dep in dependencies {
                try visit(dep)
            }

            visiting.remove(node.id)
            visited.insert(node.id)
            sorted.append(node)
        }

        for node in nodes {
            try visit(node)
        }

        return sorted
    }
}

public struct WorkflowNode: Identifiable, Codable {
    public let id: UUID
    public var type: WorkflowNodeType
    public var name: String
    public var position: CGPoint
    public var inputs: [NodePort]
    public var outputs: [NodePort]
    public var parameters: [String: AnyCodable]
    public var container: String?
    public var script: String?
}

public struct WorkflowEdge: Identifiable, Codable {
    public let id: UUID
    public let sourceNodeId: UUID
    public let sourcePort: String
    public let targetNodeId: UUID
    public let targetPort: String

    public init(sourceNodeId: UUID, sourcePort: String, targetNodeId: UUID, targetPort: String) {
        self.id = UUID()
        self.sourceNodeId = sourceNodeId
        self.sourcePort = sourcePort
        self.targetNodeId = targetNodeId
        self.targetPort = targetPort
    }
}

public struct NodePort: Codable {
    public let name: String
    public let dataType: DataType
    public let required: Bool
    public let multiple: Bool  // Can accept multiple connections

    public enum DataType: String, Codable {
        case file
        case files
        case fastq
        case fasta
        case bam
        case vcf
        case string
        case number
        case boolean
        case any

        func isCompatible(with other: DataType) -> Bool {
            if self == .any || other == .any { return true }
            if self == other { return true }
            if self == .files && other == .file { return true }
            if self == .fastq && other == .file { return true }
            if self == .fasta && other == .file { return true }
            if self == .bam && other == .file { return true }
            if self == .vcf && other == .file { return true }
            return false
        }
    }
}
```

### Canvas View
```swift
public class WorkflowCanvasView: NSView {
    public weak var delegate: WorkflowCanvasDelegate?

    private var graph: WorkflowGraph
    private var nodeViews: [UUID: NodeView] = [:]
    private var edgeLayer: CAShapeLayer!
    private var draggingConnection: (from: UUID, port: String)?
    private var currentMouseLocation: CGPoint?

    // Zoom and pan
    private var scale: CGFloat = 1.0
    private var offset: CGPoint = .zero

    public init(graph: WorkflowGraph) {
        self.graph = graph
        super.init(frame: .zero)
        setupLayers()
        setupGestures()
        rebuildViews()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        edgeLayer = CAShapeLayer()
        edgeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        edgeLayer.fillColor = nil
        edgeLayer.lineWidth = 2
        layer?.addSublayer(edgeLayer)

        // Grid background
        let gridLayer = GridLayer()
        layer?.insertSublayer(gridLayer, at: 0)
    }

    private func setupGestures() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        addGestureRecognizer(magnify)
    }

    private func rebuildViews() {
        // Remove old views
        nodeViews.values.forEach { $0.removeFromSuperview() }
        nodeViews.removeAll()

        // Create node views
        for node in graph.nodes {
            let view = NodeView(node: node)
            view.delegate = self
            addSubview(view)
            nodeViews[node.id] = view
        }

        updateEdges()
    }

    private func updateEdges() {
        let path = NSBezierPath()

        for edge in graph.edges {
            guard let sourceView = nodeViews[edge.sourceNodeId],
                  let targetView = nodeViews[edge.targetNodeId] else { continue }

            let sourcePoint = sourceView.outputPortPosition(for: edge.sourcePort)
            let targetPoint = targetView.inputPortPosition(for: edge.targetPort)

            // Draw bezier curve
            let controlOffset = abs(targetPoint.x - sourcePoint.x) * 0.5
            path.move(to: sourcePoint)
            path.curve(
                to: targetPoint,
                controlPoint1: CGPoint(x: sourcePoint.x + controlOffset, y: sourcePoint.y),
                controlPoint2: CGPoint(x: targetPoint.x - controlOffset, y: targetPoint.y)
            )
        }

        // Draw connection being dragged
        if let dragging = draggingConnection,
           let sourceView = nodeViews[dragging.from],
           let mouse = currentMouseLocation {
            let sourcePoint = sourceView.outputPortPosition(for: dragging.port)
            let controlOffset = abs(mouse.x - sourcePoint.x) * 0.5
            path.move(to: sourcePoint)
            path.curve(
                to: mouse,
                controlPoint1: CGPoint(x: sourcePoint.x + controlOffset, y: sourcePoint.y),
                controlPoint2: CGPoint(x: mouse.x - controlOffset, y: mouse.y)
            )
        }

        edgeLayer.path = path.cgPath
    }

    // Drag and drop from palette
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let data = sender.draggingPasteboard.data(forType: .nodeType),
              let nodeType = try? JSONDecoder().decode(WorkflowNodeType.self, from: data) else {
            return false
        }

        let location = convert(sender.draggingLocation, from: nil)
        let node = createNode(type: nodeType, at: location)
        graph.addNode(node)
        rebuildViews()

        return true
    }

    private func createNode(type: WorkflowNodeType, at position: CGPoint) -> WorkflowNode {
        let template = NodeTemplates.template(for: type)
        return WorkflowNode(
            id: UUID(),
            type: type,
            name: template.defaultName,
            position: position,
            inputs: template.inputs,
            outputs: template.outputs,
            parameters: template.defaultParameters,
            container: template.container,
            script: template.script
        )
    }
}

extension WorkflowCanvasView: NodeViewDelegate {
    func nodeView(_ view: NodeView, didBeginDraggingOutputPort port: String) {
        draggingConnection = (from: view.node.id, port: port)
    }

    func nodeView(_ view: NodeView, didEndDraggingAt location: CGPoint) {
        guard let dragging = draggingConnection else { return }

        // Find target node and port
        for (id, nodeView) in nodeViews {
            if id == dragging.from { continue }

            if let inputPort = nodeView.inputPort(at: convert(location, to: nodeView)) {
                do {
                    try graph.connect(
                        from: dragging.from,
                        output: dragging.port,
                        to: id,
                        input: inputPort
                    )
                } catch {
                    delegate?.canvas(self, didFailConnection: error)
                }
                break
            }
        }

        draggingConnection = nil
        currentMouseLocation = nil
        updateEdges()
    }

    func nodeView(_ view: NodeView, didMoveTo position: CGPoint) {
        if let index = graph.nodes.firstIndex(where: { $0.id == view.node.id }) {
            graph.nodes[index].position = position
        }
        updateEdges()
    }
}
```

### Nextflow Exporter
```swift
public struct NextflowExporter {
    public func export(graph: WorkflowGraph) throws -> String {
        var code = """
        #!/usr/bin/env nextflow
        nextflow.enable.dsl = 2

        /*
         * \(graph.metadata.name)
         * \(graph.metadata.description)
         * Generated by Lungfish Genome Explorer
         */

        """

        // Parameters
        code += generateParameters(graph)

        // Processes
        code += try generateProcesses(graph)

        // Workflow
        code += try generateWorkflow(graph)

        return code
    }

    private func generateParameters(_ graph: WorkflowGraph) -> String {
        var params = "// Parameters\n"

        for node in graph.nodes where node.type == .fileInput {
            let name = node.name.lowercased().replacingOccurrences(of: " ", with: "_")
            params += "params.\(name) = null\n"
        }

        params += "\n"
        return params
    }

    private func generateProcesses(_ graph: WorkflowGraph) throws -> String {
        var processes = "// Processes\n\n"

        for node in graph.nodes where node.type == .process || node.type == .script {
            processes += try generateProcess(node, in: graph)
            processes += "\n"
        }

        return processes
    }

    private func generateProcess(_ node: WorkflowNode, in graph: WorkflowGraph) throws -> String {
        let name = node.name.uppercased().replacingOccurrences(of: " ", with: "_")

        var process = "process \(name) {\n"

        // Container
        if let container = node.container {
            process += "    container '\(container)'\n"
        }

        // Inputs
        process += "\n    input:\n"
        for input in node.inputs {
            let channelType = input.multiple ? "tuple" : "path"
            process += "    \(channelType) \(input.name)\n"
        }

        // Outputs
        process += "\n    output:\n"
        for output in node.outputs {
            if let pattern = node.parameters["output_pattern"]?.value as? String {
                process += "    path '\(pattern)', emit: \(output.name)\n"
            } else {
                process += "    path '*', emit: \(output.name)\n"
            }
        }

        // Script
        process += "\n    script:\n"
        if let script = node.script {
            process += "    \"\"\"\n"
            process += "    \(script)\n"
            process += "    \"\"\"\n"
        } else {
            process += "    \"\"\"\n"
            process += "    echo 'No script defined'\n"
            process += "    \"\"\"\n"
        }

        process += "}\n"
        return process
    }

    private func generateWorkflow(_ graph: WorkflowGraph) throws -> String {
        let sorted = try graph.executionOrder()

        var workflow = "// Main workflow\nworkflow {\n"

        // Input channels
        workflow += "    // Input channels\n"
        for node in sorted where node.type == .fileInput {
            let name = node.name.lowercased().replacingOccurrences(of: " ", with: "_")
            workflow += "    \(name)_ch = Channel.fromPath(params.\(name))\n"
        }
        workflow += "\n"

        // Process calls
        workflow += "    // Process execution\n"
        for node in sorted where node.type == .process || node.type == .script {
            let name = node.name.uppercased().replacingOccurrences(of: " ", with: "_")

            // Find input channels
            let inputs = graph.edges
                .filter { $0.targetNodeId == node.id }
                .map { edge -> String in
                    if let sourceNode = graph.nodes.first(where: { $0.id == edge.sourceNodeId }) {
                        if sourceNode.type == .fileInput {
                            return sourceNode.name.lowercased().replacingOccurrences(of: " ", with: "_") + "_ch"
                        } else {
                            return sourceNode.name.uppercased().replacingOccurrences(of: " ", with: "_") + ".out.\(edge.sourcePort)"
                        }
                    }
                    return ""
                }
                .joined(separator: ", ")

            workflow += "    \(name)(\(inputs))\n"
        }

        workflow += "}\n"
        return workflow
    }
}
```

### Node Palette
```swift
public struct NodePaletteView: View {
    @State private var searchText = ""
    @State private var selectedCategory: NodeCategory?

    public var body: some View {
        VStack(spacing: 0) {
            // Search
            TextField("Search nodes...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding()

            // Categories
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(NodeCategory.allCases, id: \.self) { category in
                        Button(action: { selectedCategory = category }) {
                            Label(category.displayName, systemImage: category.sfSymbol)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedCategory == category ? .accentColor : .secondary)
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            // Nodes
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                    ForEach(filteredNodes, id: \.self) { nodeType in
                        NodePaletteItem(nodeType: nodeType)
                            .draggable(nodeType.rawValue)
                    }
                }
                .padding()
            }
        }
    }

    private var filteredNodes: [WorkflowNodeType] {
        WorkflowNodeType.allCases.filter { nodeType in
            if let category = selectedCategory, nodeType.category != category {
                return false
            }
            if !searchText.isEmpty {
                return nodeType.rawValue.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }
}

public struct NodePaletteItem: View {
    public let nodeType: WorkflowNodeType

    public var body: some View {
        VStack {
            Image(systemName: nodeType.sfSymbol)
                .font(.title)
                .frame(width: 44, height: 44)
                .background(nodeType.category.color.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(nodeType.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 80)
    }
}

public enum NodeCategory: CaseIterable {
    case io
    case processing
    case flowControl
    case dataManipulation
    case bioinformatics

    var displayName: String {
        switch self {
        case .io: return "I/O"
        case .processing: return "Processing"
        case .flowControl: return "Flow"
        case .dataManipulation: return "Data"
        case .bioinformatics: return "Bio"
        }
    }

    var sfSymbol: String {
        switch self {
        case .io: return "doc"
        case .processing: return "gearshape"
        case .flowControl: return "arrow.triangle.branch"
        case .dataManipulation: return "tablecells"
        case .bioinformatics: return "dna"
        }
    }

    var color: Color {
        switch self {
        case .io: return .blue
        case .processing: return .orange
        case .flowControl: return .purple
        case .dataManipulation: return .green
        case .bioinformatics: return .pink
        }
    }
}
```
