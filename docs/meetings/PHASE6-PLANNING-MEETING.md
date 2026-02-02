# Expert Review Meeting #011 - Phase 6 Planning

**Date:** 2026-02-01
**Phase:** 6 - Workflow Integration (Nextflow/Snakemake)
**Status:** PLANNING (UPDATED)
**Last Updated:** 2026-02-01 - Added Apple Containerization integration per Role 21 briefing

---

## Meeting Attendees (All 21 Experts)

All experts present and contributing to Phase 6 planning.

**New Addition:** Apple Containerization Expert (Role 21) has joined to advise on container runtime strategy.

---

## Phase 6 Overview

Phase 6 implements comprehensive workflow integration for bioinformatics pipelines:

1. **Nextflow Runner** - Execute Nextflow pipelines with native macOS UI
2. **Snakemake Runner** - Execute Snakemake workflows with config parsing
3. **Parameter UI Generator** - Dynamic UI from workflow schemas
4. **Visual Workflow Builder** - Node-based graph editor
5. **Workflow Export** - Generate Nextflow/Snakemake from visual workflows

### Key Features
- **Apple Containerization as PRIMARY runtime** (macOS 26+, Apple Silicon) - NEW
- Docker as FALLBACK container runtime (older macOS or user preference)
- ~~Apptainer/Singularity support~~ REMOVED - not applicable to desktop macOS
- Nextflow schema.json parsing for native macOS parameter UI
- Snakemake config.yaml parsing for configuration
- Visual workflow builder using native AppKit node canvas
- nf-core pipeline integration and discovery
- Real-time workflow execution monitoring
- Comprehensive logging with os.log

### Container Runtime Strategy Update (per Role 21 Briefing)

**See:** [APPLE-CONTAINERIZATION-BRIEFING.md](./APPLE-CONTAINERIZATION-BRIEFING.md)

Apple Containerization (announced WWDC 2025) provides significant advantages:

| Feature | Apple Containerization | Docker Desktop |
|---------|----------------------|----------------|
| Startup Time | <0.5s | ~2s |
| Memory Model | VM per container | Shared VM |
| Network | Dedicated IPs | Port forwarding |
| Swift Integration | Native APIs | CLI/REST only |
| Dependencies | Ships with macOS 26 | External install |
| Security | VM isolation | Namespace isolation |

**Decision:** Use Apple Containerization as PRIMARY, Docker as FALLBACK.

---

## Phase 5 Completion Summary

Phase 5 successfully delivered:
- **NCBIService** - Full Entrez E-utilities integration
- **ENAService** - Portal/Browser API integration
- **PathoplexusService** - Browse, search, import, submission
- **GenBankReader** - Complete GenBank format parser with annotations
- **SequenceTrack** - Multi-level zoom rendering with tile caching
- **521 tests passing** with comprehensive coverage

---

## Expert Task Delegation

### Week 1: Workflow Foundation (Core Infrastructure)

#### Swift Architecture Lead (Role 01)
**Focus:** Module structure, async patterns, actor design

**Deliverables:**
- `Sources/LungfishWorkflow/WorkflowRunner.swift` - Base protocol and actor
- `Sources/LungfishWorkflow/ProcessManager.swift` - NSTask/Process wrapper
- `Sources/LungfishWorkflow/WorkflowState.swift` - State machine for execution
- `Sources/LungfishWorkflow/WorkflowError.swift` - Error types

**Technical Requirements:**
```swift
// WorkflowRunner.swift - Base protocol for workflow execution
// Owner: Swift Architecture Lead (Role 01)

import Foundation
import os.log

/// Logger for workflow operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "WorkflowRunner")

/// Protocol defining workflow runner capabilities.
///
/// Implementations handle specific workflow engines like Nextflow or Snakemake.
public protocol WorkflowRunner: Actor {
    /// The workflow engine type
    var engineType: WorkflowEngineType { get }

    /// Whether the workflow engine is available on this system
    func isAvailable() async -> Bool

    /// Returns the version of the workflow engine
    func version() async throws -> String

    /// Executes a workflow with the given configuration
    func execute(workflow: WorkflowDefinition, parameters: WorkflowParameters) async throws -> WorkflowExecution

    /// Cancels a running workflow
    func cancel(execution: WorkflowExecution) async throws

    /// Returns the current status of an execution
    func status(execution: WorkflowExecution) async -> WorkflowStatus
}

/// Workflow engine types
public enum WorkflowEngineType: String, Sendable, CaseIterable {
    case nextflow = "Nextflow"
    case snakemake = "Snakemake"
}

/// Workflow execution state machine
public enum WorkflowStatus: Sendable, Equatable {
    case pending
    case starting
    case running(progress: Double, currentTask: String?)
    case paused
    case completed(WorkflowResult)
    case failed(WorkflowError)
    case cancelled
}
```

**Acceptance Criteria:**
- All async operations use structured concurrency
- Actor isolation prevents data races
- State machine handles all transitions
- Comprehensive logging with os.log

---

#### Workflow Integration Lead (Role 14)
**Focus:** Nextflow/Snakemake runners, container orchestration

**Deliverables:**
- `Sources/LungfishWorkflow/Engines/NextflowRunner.swift` - Nextflow execution
- `Sources/LungfishWorkflow/Engines/SnakemakeRunner.swift` - Snakemake execution
- `Sources/LungfishWorkflow/Engines/ContainerRuntimeProtocol.swift` - Abstract runtime protocol (NEW)
- `Sources/LungfishWorkflow/Engines/AppleContainerRuntime.swift` - Apple Containerization (NEW, PRIMARY)
- `Sources/LungfishWorkflow/Engines/DockerRuntime.swift` - Docker fallback (NEW)
- `Sources/LungfishWorkflow/Engines/ContainerRuntimeFactory.swift` - Runtime selection (NEW)
- `Sources/LungfishWorkflow/Engines/ContainerRuntime.swift` - DEPRECATED, kept for migration
- `Sources/LungfishWorkflow/Schema/NextflowSchemaParser.swift` - schema.json parsing
- `Sources/LungfishWorkflow/Schema/SnakemakeConfigParser.swift` - config.yaml parsing

**Technical Requirements (UPDATED for Apple Containerization):**
```swift
// ContainerRuntimeProtocol.swift - Abstract container runtime protocol
// Owner: Workflow Integration Lead (Role 14) with guidance from Role 21

import Foundation

/// Protocol defining container runtime capabilities.
///
/// Implementations handle specific container runtimes like Apple Containerization
/// or Docker. Runtime selection priority:
/// 1. Apple Containerization (macOS 26+, Apple Silicon) - PRIMARY
/// 2. Docker (fallback for older systems or user preference)
public protocol ContainerRuntimeProtocol: Actor, Sendable {
    /// The runtime type identifier
    var runtimeType: ContainerRuntimeType { get }

    /// Human-readable name of the runtime
    var displayName: String { get }

    /// Whether this runtime is available on the current system
    func isAvailable() async -> Bool

    /// Returns the version of the runtime
    func version() async throws -> String

    /// Pulls an OCI image from a registry
    func pullImage(reference: String) async throws -> ContainerImage

    /// Creates a container from an image
    func createContainer(
        name: String,
        image: ContainerImage,
        config: ContainerConfig
    ) async throws -> Container

    /// Starts a container
    func startContainer(_ container: Container) async throws

    /// Stops a container
    func stopContainer(_ container: Container) async throws

    /// Executes a process in a running container
    func exec(
        in container: Container,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) async throws -> ContainerProcess

    /// Removes a container
    func removeContainer(_ container: Container) async throws
}

/// Container runtime types
public enum ContainerRuntimeType: String, Sendable, CaseIterable {
    case appleContainerization = "apple"
    case docker = "docker"

    public var displayName: String {
        switch self {
        case .appleContainerization: return "Apple Containerization"
        case .docker: return "Docker"
        }
    }

    public var iconName: String {
        switch self {
        case .appleContainerization: return "apple.logo"
        case .docker: return "shippingbox"
        }
    }
}
```

```swift
// ContainerRuntimeFactory.swift - Runtime selection logic
// Owner: Workflow Integration Lead (Role 14)

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "ContainerRuntimeFactory")

/// Factory for selecting and creating container runtimes.
///
/// Runtime selection priority:
/// 1. Apple Containerization (macOS 26+, Apple Silicon) - PRIMARY
/// 2. Docker (fallback for older systems or user preference)
///
/// Apptainer/Singularity support has been REMOVED as it provides no value
/// on desktop macOS (designed for HPC without root access).
public enum ContainerRuntimeFactory {

    /// User preference for container runtime
    public enum Preference: String, Sendable {
        case automatic  // Let the system choose (recommended)
        case apple      // Force Apple Containerization
        case docker     // Force Docker
    }

    /// Creates the best available container runtime.
    ///
    /// - Parameter preference: User preference for runtime selection
    /// - Returns: A container runtime, or nil if none available
    public static func createRuntime(
        preference: Preference = .automatic
    ) async -> (any ContainerRuntimeProtocol)? {

        switch preference {
        case .apple:
            if let runtime = await createAppleRuntime() {
                return runtime
            }
            logger.warning("Apple Containerization requested but not available")
            return nil

        case .docker:
            if let runtime = await createDockerRuntime() {
                return runtime
            }
            logger.warning("Docker requested but not available")
            return nil

        case .automatic:
            // Try Apple Containerization first (PRIMARY)
            if let appleRuntime = await createAppleRuntime() {
                logger.info("Using Apple Containerization runtime (primary)")
                return appleRuntime
            }

            // Fall back to Docker
            if let dockerRuntime = await createDockerRuntime() {
                logger.info("Using Docker runtime (fallback)")
                return dockerRuntime
            }

            logger.error("No container runtime available")
            return nil
        }
    }

    /// Checks if Apple Containerization is available.
    public static func isAppleContainerizationAvailable() -> Bool {
        if #available(macOS 26, *) {
            #if arch(arm64)
            return true
            #else
            return false  // Intel Macs not supported
            #endif
        }
        return false
    }

    // ... implementation details ...
}
```

```swift
// AppleContainerRuntime.swift - Apple Containerization implementation
// Owner: Workflow Integration Lead (Role 14) with guidance from Role 21
// Requires: macOS 26+, Apple Silicon

#if canImport(Containerization)
import Containerization
import ContainerizationOCI
import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "AppleContainerRuntime")

/// Apple Containerization runtime implementation.
///
/// This is the PRIMARY container runtime for Lungfish on macOS 26+.
///
/// Key advantages over Docker:
/// - Native Swift APIs (no subprocess spawning)
/// - Sub-second container startup
/// - VM isolation (better security than namespace isolation)
/// - Dedicated IP per container (no port forwarding)
/// - No external daemon required
/// - Ships with macOS 26
@available(macOS 26, *)
public actor AppleContainerRuntime: ContainerRuntimeProtocol {
    public let runtimeType: ContainerRuntimeType = .appleContainerization
    public let displayName: String = "Apple Containerization"

    private let vmm: VirtualMachineManager
    private let imageStore: OCIImageStore

    public init() async throws {
        self.vmm = try VirtualMachineManager()

        let storePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lungfish.containers")
        self.imageStore = try OCIImageStore(path: storePath)

        logger.info("Apple Containerization runtime initialized")
    }

    public func isAvailable() async -> Bool {
        return true  // Always available on macOS 26+ Apple Silicon
    }

    public func pullImage(reference: String) async throws -> ContainerImage {
        logger.info("Pulling image: \(reference, privacy: .public)")

        let imageRef = try OCIImageReference(reference)

        let pullOptions = OCIPullOptions(
            platform: .init(os: "linux", architecture: "arm64"),
            progressHandler: { progress in
                logger.debug("Pull progress: \(progress.fractionCompleted * 100, format: .fixed(precision: 1))%")
            }
        )

        let image = try await imageStore.pull(imageRef, options: pullOptions)

        logger.info("Image pulled: \(image.digest, privacy: .public)")

        return ContainerImage(
            reference: reference,
            digest: image.digest,
            rootfsPath: image.rootfsPath
        )
    }

    public func createContainer(
        name: String,
        image: ContainerImage,
        config: ContainerConfig
    ) async throws -> Container {
        logger.info("Creating container: \(name, privacy: .public)")

        let rootfsMount = try RootFSMount(path: image.rootfsPath)

        let linuxContainer = try LinuxContainer(
            name,
            rootfs: rootfsMount,
            vmm: vmm
        ) { vmConfig in
            vmConfig.cpus = config.cpuCount ?? ProcessInfo.processInfo.activeProcessorCount
            vmConfig.memoryInBytes = config.memoryBytes ?? 8.gib()
            vmConfig.hostname = name
            vmConfig.networking = .vmnet(mode: .shared)

            // Add mount bindings
            if let mounts = config.mounts {
                vmConfig.mounts = mounts.map { mount in
                    .bind(source: mount.hostPath, destination: mount.containerPath, readOnly: mount.readOnly)
                }
            }
        }

        return Container(
            id: UUID(),
            name: name,
            runtime: .appleContainerization,
            nativeContainer: linuxContainer
        )
    }

    // ... additional methods per ContainerRuntimeProtocol ...
}
#endif
```

```swift
// NextflowRunner.swift - Nextflow workflow execution (UPDATED)
// Owner: Workflow Integration Lead (Role 14)

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "NextflowRunner")

/// Actor managing Nextflow workflow execution.
///
/// Handles:
/// - Nextflow CLI detection and version checking
/// - Pipeline execution with parameter injection
/// - Container runtime configuration (Apple Containerization PRIMARY, Docker fallback)
/// - Real-time log streaming
/// - Process lifecycle management
public actor NextflowRunner: WorkflowRunner {
    public let engineType: WorkflowEngineType = .nextflow

    /// Path to Nextflow executable
    private var nextflowPath: String?

    /// Selected container runtime
    private var containerRuntime: (any ContainerRuntimeProtocol)?

    /// Active executions
    private var executions: [UUID: ProcessHandle] = [:]

    public init() {
        Task {
            await detectNextflow()
            await detectContainerRuntime()
        }
    }

    private func detectContainerRuntime() async {
        // Use ContainerRuntimeFactory - Apple Containerization is PRIMARY
        containerRuntime = await ContainerRuntimeFactory.createRuntime(preference: .automatic)

        if let runtime = containerRuntime {
            logger.info("Container runtime selected: \(runtime.displayName, privacy: .public)")
        } else {
            logger.warning("No container runtime available - workflows may fail")
        }
    }

    public func isAvailable() async -> Bool {
        nextflowPath != nil
    }

    public func execute(workflow: WorkflowDefinition, parameters: WorkflowParameters) async throws -> WorkflowExecution {
        guard let nfPath = nextflowPath else {
            throw WorkflowError.engineNotFound(.nextflow)
        }

        logger.info("Starting Nextflow execution: \(workflow.name, privacy: .public)")

        // Build command line arguments
        var arguments = ["run", workflow.path.path]

        // Add profile for container runtime
        if let runtime = containerRuntime {
            arguments.append("-profile")
            switch runtime.runtimeType {
            case .appleContainerization:
                // Apple Containerization uses docker-compatible images
                arguments.append("docker")
            case .docker:
                arguments.append("docker")
            }
        }

        // Add parameters
        for (key, value) in parameters.values {
            arguments.append("--\(key)")
            arguments.append(value.stringValue)
        }

        // Execute process
        let handle = try await ProcessManager.shared.spawn(
            executable: nfPath,
            arguments: arguments,
            workingDirectory: workflow.workDirectory
        )

        let execution = WorkflowExecution(
            id: UUID(),
            workflow: workflow,
            parameters: parameters,
            startTime: Date()
        )

        executions[execution.id] = handle

        return execution
    }
}
```

**Acceptance Criteria (UPDATED):**
- Nextflow CLI detection works on macOS
- Apple Containerization detected as PRIMARY on macOS 26+
- Docker detected as FALLBACK
- ~~Apptainer/Singularity~~ REMOVED
- schema.json parsed to WorkflowSchema model
- config.yaml parsed to SnakemakeConfig model
- Process output streamed in real-time

---

### Week 2: Schema Parsing and Parameter Models

#### Workflow Integration Lead (Role 14) (continued)
**Focus:** Complete schema parsing implementations

**Deliverables:**
- `Sources/LungfishWorkflow/Schema/WorkflowSchema.swift` - Unified schema model
- `Sources/LungfishWorkflow/Schema/NextflowSchemaParser.swift` - nf-core schema.json
- `Sources/LungfishWorkflow/Schema/SnakemakeConfigParser.swift` - Snakemake config

**Technical Requirements:**
```swift
// WorkflowSchema.swift - Unified workflow parameter schema
// Owner: Workflow Integration Lead (Role 14)

import Foundation

/// A unified schema for workflow parameters.
///
/// Supports both Nextflow schema.json and Snakemake config.yaml formats.
public struct WorkflowSchema: Sendable, Codable {
    /// Schema title/name
    public let title: String

    /// Schema description
    public let description: String?

    /// Parameter groups
    public let groups: [ParameterGroup]

    /// All parameters flattened
    public var allParameters: [WorkflowParameter] {
        groups.flatMap { $0.parameters }
    }
}

/// A group of related parameters.
public struct ParameterGroup: Sendable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let description: String?
    public let parameters: [WorkflowParameter]
    public let isHidden: Bool
    public let icon: String?
}

/// A single workflow parameter with type and validation.
public struct WorkflowParameter: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let type: ParameterType
    public let defaultValue: ParameterValue?
    public let isRequired: Bool
    public let isHidden: Bool
    public let validation: ParameterValidation?
    public let helpText: String?
}

/// Parameter value types
public enum ParameterType: Sendable, Codable {
    case string
    case integer
    case number
    case boolean
    case file(pattern: String?)
    case directory
    case enumeration([String])
    case array(elementType: ParameterType)
}

/// Parameter validation rules
public struct ParameterValidation: Sendable, Codable {
    public let pattern: String?
    public let minimum: Double?
    public let maximum: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let options: [String]?
}
```

**Nextflow schema.json example:**
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "nf-core/rnaseq",
  "description": "RNA sequencing analysis pipeline",
  "definitions": {
    "input_output_options": {
      "title": "Input/output options",
      "type": "object",
      "fa_icon": "fas fa-terminal",
      "properties": {
        "input": {
          "type": "string",
          "format": "file-path",
          "description": "Path to samplesheet",
          "help_text": "CSV file with sample information"
        },
        "outdir": {
          "type": "string",
          "format": "directory-path",
          "description": "Output directory"
        }
      },
      "required": ["input", "outdir"]
    }
  }
}
```

---

#### UI/UX Lead (Role 02)
**Focus:** Parameter UI generation, macOS HIG compliance

**Deliverables:**
- `Sources/LungfishApp/Views/Workflow/ParameterFormView.swift` - Dynamic form generator
- `Sources/LungfishApp/Views/Workflow/ParameterControlFactory.swift` - Control factory
- `Sources/LungfishApp/Views/Workflow/WorkflowConfigurationPanel.swift` - Config panel
- `Sources/LungfishApp/Views/Workflow/WorkflowExecutionView.swift` - Execution monitor
- `Sources/LungfishApp/Views/Workflow/ContainerRuntimeSelector.swift` - Runtime preference UI (NEW)

**Technical Requirements:**
```swift
// ParameterFormView.swift - Dynamic parameter UI generation
// Owner: UI/UX Lead (Role 02)

import AppKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "ParameterFormView")

/// A view that dynamically generates parameter input forms from workflow schemas.
///
/// Follows macOS Human Interface Guidelines:
/// - Uses standard AppKit controls
/// - Proper label alignment and spacing
/// - Keyboard navigation support
/// - Validation feedback
@MainActor
public class ParameterFormView: NSView {

    /// The schema driving this form
    private let schema: WorkflowSchema

    /// Current parameter values
    private var values: [String: ParameterValue] = [:]

    /// Validation state for each parameter
    private var validationState: [String: ValidationResult] = [:]

    /// Delegate for value changes
    public weak var delegate: ParameterFormDelegate?

    /// Stack view containing parameter groups
    private let stackView: NSStackView

    /// Control references for value extraction
    private var controls: [String: NSControl] = [:]

    public init(schema: WorkflowSchema) {
        self.schema = schema
        self.stackView = NSStackView()
        super.init(frame: .zero)
        setupUI()
        buildForm()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // ... implementation as before ...
}
```

```swift
// ContainerRuntimeSelector.swift - Container runtime preference UI (NEW)
// Owner: UI/UX Lead (Role 02)

import AppKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "ContainerRuntimeSelector")

/// A view for selecting container runtime preference.
///
/// Displays available runtimes and allows user to override automatic selection.
@MainActor
public class ContainerRuntimeSelector: NSView {

    private let popupButton: NSPopUpButton
    private let statusLabel: NSTextField
    private let refreshButton: NSButton

    private var availableRuntimes: [any ContainerRuntimeProtocol] = []

    public var selectedPreference: ContainerRuntimeFactory.Preference = .automatic {
        didSet {
            updateSelection()
        }
    }

    public override init(frame frameRect: NSRect) {
        self.popupButton = NSPopUpButton()
        self.statusLabel = NSTextField(labelWithString: "")
        self.refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: nil,
            action: nil
        )
        super.init(frame: frameRect)
        setupUI()
        refreshRuntimes()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8

        let label = NSTextField(labelWithString: "Container Runtime:")
        label.font = .systemFont(ofSize: 13)

        popupButton.addItems(withTitles: [
            "Automatic (Recommended)",
            "Apple Containerization",
            "Docker"
        ])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        refreshButton.bezelStyle = .inline
        refreshButton.target = self
        refreshButton.action = #selector(refreshRuntimes)

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(popupButton)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(refreshButton)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func refreshRuntimes() {
        Task {
            availableRuntimes = await ContainerRuntimeFactory.availableRuntimes()
            updateStatus()
        }
    }

    private func updateStatus() {
        if availableRuntimes.isEmpty {
            statusLabel.stringValue = "No runtime available"
            statusLabel.textColor = .systemRed
        } else if let apple = availableRuntimes.first(where: { $0.runtimeType == .appleContainerization }) {
            statusLabel.stringValue = "Using \(apple.displayName)"
            statusLabel.textColor = .systemGreen
        } else if let docker = availableRuntimes.first(where: { $0.runtimeType == .docker }) {
            statusLabel.stringValue = "Using \(docker.displayName) (fallback)"
            statusLabel.textColor = .systemOrange
        }
    }

    private func updateSelection() {
        switch selectedPreference {
        case .automatic:
            popupButton.selectItem(at: 0)
        case .apple:
            popupButton.selectItem(at: 1)
        case .docker:
            popupButton.selectItem(at: 2)
        }
    }
}
```

**Acceptance Criteria:**
- All parameter types rendered with appropriate controls
- Validation feedback shown inline
- Keyboard navigation works throughout
- HIG-compliant spacing and typography
- Accessibility labels for VoiceOver
- Container runtime selector shows available runtimes (NEW)

---

### Week 3: Visual Workflow Builder

#### Visual Workflow Builder (Role 16)
**Focus:** Node-based graph editor using AppKit

**Deliverables:**
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowCanvasView.swift` - Main canvas
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodeView.swift` - Node rendering
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowConnectionView.swift` - Connection lines
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodePalette.swift` - Node palette
- `Sources/LungfishWorkflow/Builder/WorkflowGraph.swift` - Graph data model

(Technical requirements unchanged from original plan)

**Acceptance Criteria:**
- Nodes can be dragged from palette onto canvas
- Connections drawn with Bezier curves
- Pan and zoom with trackpad gestures
- Undo/redo for all operations
- Cycle detection prevents invalid graphs
- Export to Nextflow/Snakemake

---

### Week 4: Integration, Testing, and Polish

#### Testing & QA Lead (Role 19)
**Focus:** Comprehensive workflow tests

**Deliverables:**
- `Tests/LungfishWorkflowTests/NextflowRunnerTests.swift`
- `Tests/LungfishWorkflowTests/SnakemakeRunnerTests.swift`
- `Tests/LungfishWorkflowTests/SchemaParserTests.swift`
- `Tests/LungfishWorkflowTests/WorkflowGraphTests.swift`
- `Tests/LungfishWorkflowTests/ContainerRuntimeFactoryTests.swift` - NEW
- `Tests/LungfishWorkflowTests/AppleContainerRuntimeTests.swift` - NEW
- `Tests/LungfishWorkflowTests/DockerRuntimeTests.swift` - NEW
- `Tests/LungfishWorkflowTests/Mocks/MockProcessManager.swift`
- `Tests/LungfishWorkflowTests/Mocks/MockContainerRuntime.swift` - UPDATED
- `Tests/LungfishWorkflowTests/Resources/` - Test schemas and configs

**Test Coverage Requirements (UPDATED):**

| Component | Target Coverage |
|-----------|----------------|
| NextflowRunner | 90% |
| SnakemakeRunner | 90% |
| NextflowSchemaParser | 95% |
| SnakemakeConfigParser | 95% |
| WorkflowGraph | 95% |
| ParameterFormView | 85% |
| WorkflowCanvasView | 85% |
| ProcessManager | 90% |
| **ContainerRuntimeFactory** | **95%** (NEW) |
| **AppleContainerRuntime** | **90%** (NEW) |
| **DockerRuntime** | **90%** (NEW) |

**New Test Categories:**

```swift
// ContainerRuntimeFactoryTests.swift
// Owner: Testing & QA Lead (Role 19)

import XCTest
@testable import LungfishWorkflow

final class ContainerRuntimeFactoryTests: XCTestCase {

    // MARK: - Automatic Selection Tests

    func testCreateRuntime_Automatic_PrefersAppleContainerization() async throws {
        // On macOS 26+ Apple Silicon, should select Apple Containerization
        guard ContainerRuntimeFactory.isAppleContainerizationAvailable() else {
            throw XCTSkip("Apple Containerization not available")
        }

        let runtime = await ContainerRuntimeFactory.createRuntime(preference: .automatic)

        XCTAssertNotNil(runtime)
        XCTAssertEqual(runtime?.runtimeType, .appleContainerization)
    }

    func testCreateRuntime_Automatic_FallsBackToDocker() async throws {
        // This test would need mocking to simulate macOS < 26
        // When Apple Containerization unavailable, should fall back to Docker
    }

    // MARK: - Explicit Preference Tests

    func testCreateRuntime_ExplicitApple_ReturnsAppleRuntime() async throws {
        guard ContainerRuntimeFactory.isAppleContainerizationAvailable() else {
            throw XCTSkip("Apple Containerization not available")
        }

        let runtime = await ContainerRuntimeFactory.createRuntime(preference: .apple)

        XCTAssertNotNil(runtime)
        XCTAssertEqual(runtime?.runtimeType, .appleContainerization)
    }

    func testCreateRuntime_ExplicitDocker_ReturnsDockerRuntime() async throws {
        let runtime = await ContainerRuntimeFactory.createRuntime(preference: .docker)

        // May be nil if Docker not installed
        if runtime != nil {
            XCTAssertEqual(runtime?.runtimeType, .docker)
        }
    }

    // MARK: - Availability Tests

    func testIsAppleContainerizationAvailable_OnMacOS26_ReturnsTrue() {
        if #available(macOS 26, *) {
            #if arch(arm64)
            XCTAssertTrue(ContainerRuntimeFactory.isAppleContainerizationAvailable())
            #else
            XCTAssertFalse(ContainerRuntimeFactory.isAppleContainerizationAvailable())
            #endif
        } else {
            XCTAssertFalse(ContainerRuntimeFactory.isAppleContainerizationAvailable())
        }
    }

    // MARK: - Available Runtimes Tests

    func testAvailableRuntimes_ReturnsNonEmpty() async {
        let runtimes = await ContainerRuntimeFactory.availableRuntimes()

        // At least one runtime should be available in test environment
        // (either Apple Containerization or Docker)
        XCTAssertFalse(runtimes.isEmpty, "Expected at least one container runtime")
    }
}
```

**Acceptance Criteria (UPDATED):**
- All tests pass without network access (mocked)
- 90%+ coverage on core components
- 95%+ coverage on ContainerRuntimeFactory
- No flaky tests
- All error paths tested
- Performance tests for large graphs
- Container runtime selection tested on multiple configurations

---

## Dependency Graph (UPDATED)

```
Week 1:
  Swift Architecture Lead (01) ──────────────────────────────────────┐
         │                                                            │
         ▼                                                            │
  WorkflowRunner.swift                                                │
  ProcessManager.swift                                                │
  WorkflowState.swift                                                 │
  WorkflowError.swift                                                 │
         │                                                            │
         └───────────────────────┬────────────────────────────────────┘
                                 │
Week 2:                          ▼
  Workflow Integration Lead (14) ─────────────────────────────────────┐
         │                                                            │
         ▼                                                            │
  NextflowRunner.swift                                                │
  SnakemakeRunner.swift                                               │
  ContainerRuntimeProtocol.swift (NEW)                                │
  AppleContainerRuntime.swift (NEW, PRIMARY)                          │
  DockerRuntime.swift (NEW, FALLBACK)                                 │
  ContainerRuntimeFactory.swift (NEW)                                 │
  NextflowSchemaParser.swift ───────────────────┐                     │
  SnakemakeConfigParser.swift                   │                     │
         │                                      │                     │
         │                                      ▼                     │
         │                      UI/UX Lead (02) ─────────────────────┤
         │                             │                              │
         │                             ▼                              │
         │                      ParameterFormView.swift               │
         │                      ParameterControlFactory.swift         │
         │                      WorkflowConfigurationPanel.swift      │
         │                      ContainerRuntimeSelector.swift (NEW)  │
         │                                                            │
Week 3:  │                                                            │
         └────────────────────────────────────────────────────────────┤
                                 │                                    │
                                 ▼                                    │
  Visual Workflow Builder (16) ───────────────────────────────────────┤
         │                                                            │
         ▼                                                            │
  WorkflowGraph.swift                                                 │
  WorkflowCanvasView.swift                                            │
  WorkflowNodeView.swift                                              │
  WorkflowConnectionView.swift                                        │
  NextflowExporter.swift                                              │
  SnakemakeExporter.swift                                             │
         │                                                            │
Week 4:  │                                                            │
         └────────────────────────────────────────────────────────────┤
                                                                      │
  Testing & QA Lead (19) ◀────────────────────────────────────────────┘
         │
         ▼
  All test files
  Mock infrastructure
  Test resources
  ContainerRuntimeFactoryTests.swift (NEW)
  AppleContainerRuntimeTests.swift (NEW)
  DockerRuntimeTests.swift (NEW)
```

---

## File Structure (UPDATED)

```
Sources/LungfishWorkflow/
├── WorkflowRunner.swift                    # Role 01
├── ProcessManager.swift                    # Role 01
├── WorkflowState.swift                     # Role 01
├── WorkflowError.swift                     # Role 01
├── WorkflowDefinition.swift                # Role 01
├── WorkflowParameters.swift                # Role 01
├── Engines/
│   ├── NextflowRunner.swift                # Role 14 (UPDATED)
│   ├── SnakemakeRunner.swift               # Role 14 (UPDATED)
│   ├── ContainerRuntimeProtocol.swift      # Role 14 (NEW)
│   ├── AppleContainerRuntime.swift         # Role 14 (NEW, PRIMARY)
│   ├── DockerRuntime.swift                 # Role 14 (NEW, FALLBACK)
│   ├── ContainerRuntimeFactory.swift       # Role 14 (NEW)
│   └── ContainerRuntime.swift              # Role 14 (DEPRECATED)
├── Containers/                             # NEW DIRECTORY
│   ├── ContainerConfiguration.swift        # Role 14 (NEW)
│   ├── ContainerImage.swift                # Role 14 (NEW)
│   ├── Container.swift                     # Role 14 (NEW)
│   ├── ContainerProcess.swift              # Role 14 (NEW)
│   └── ContainerLogStreamer.swift          # Role 14 (NEW)
├── Schema/
│   ├── WorkflowSchema.swift                # Role 14
│   ├── NextflowSchemaParser.swift          # Role 14
│   └── SnakemakeConfigParser.swift         # Role 14
├── Builder/
│   ├── WorkflowGraph.swift                 # Role 16
│   ├── WorkflowNode.swift                  # Role 16
│   ├── WorkflowConnection.swift            # Role 16
│   ├── NextflowExporter.swift              # Role 16
│   └── SnakemakeExporter.swift             # Role 16
└── nf-core/
    ├── NFCoreRegistry.swift                # Role 14
    └── NFCorePipeline.swift                # Role 14

Sources/LungfishApp/Views/Workflow/
├── ParameterFormView.swift                 # Role 02
├── ParameterControlFactory.swift           # Role 02
├── WorkflowConfigurationPanel.swift        # Role 02
├── WorkflowExecutionView.swift             # Role 02
├── WorkflowLogView.swift                   # Role 02
└── ContainerRuntimeSelector.swift          # Role 02 (NEW)

Sources/LungfishApp/Views/WorkflowBuilder/
├── WorkflowCanvasView.swift                # Role 16
├── WorkflowNodeView.swift                  # Role 16
├── WorkflowConnectionView.swift            # Role 16
├── WorkflowNodePalette.swift               # Role 16
└── WorkflowBuilderViewController.swift     # Role 16

Tests/LungfishWorkflowTests/
├── NextflowRunnerTests.swift               # Role 19
├── SnakemakeRunnerTests.swift              # Role 19
├── NextflowSchemaParserTests.swift         # Role 19
├── SnakemakeConfigParserTests.swift        # Role 19
├── WorkflowGraphTests.swift                # Role 19
├── ProcessManagerTests.swift               # Role 19
├── ContainerRuntimeFactoryTests.swift      # Role 19 (NEW)
├── AppleContainerRuntimeTests.swift        # Role 19 (NEW)
├── DockerRuntimeTests.swift                # Role 19 (NEW)
├── Mocks/
│   ├── MockProcessManager.swift            # Role 19
│   └── MockContainerRuntime.swift          # Role 19 (UPDATED)
└── Resources/
    ├── nf-core-rnaseq-schema.json          # Role 19
    ├── snakemake-config.yaml               # Role 19
    └── simple-workflow.nf                  # Role 19
```

---

## Package.swift Updates Required

```swift
// Package.swift additions for Apple Containerization

let package = Package(
    name: "LungfishGenomeBrowser",
    platforms: [
        .macOS(.v14)  // Keep .v14 for backward compatibility
        // Apple Containerization features gated with #available(macOS 26, *)
    ],
    dependencies: [
        // ... existing dependencies ...

        // Apple Containerization (macOS 26+)
        // Conditionally included based on availability
        .package(
            url: "https://github.com/apple/containerization.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "LungfishWorkflow",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                .product(
                    name: "Containerization",
                    package: "containerization",
                    condition: .when(platforms: [.macOS])
                ),
                .product(
                    name: "ContainerizationOCI",
                    package: "containerization",
                    condition: .when(platforms: [.macOS])
                ),
            ],
            path: "Sources/LungfishWorkflow"
        ),
    ]
)
```

---

## Timeline (UPDATED)

| Week | Activities | Owner(s) |
|------|------------|----------|
| Week 1 | Core infrastructure: WorkflowRunner protocol, ProcessManager, state machine | Role 01 |
| Week 2 | Runners: Nextflow/Snakemake execution, schema parsing | Role 14 |
| Week 2 | **Container runtime: Apple Containerization (PRIMARY), Docker (FALLBACK)** | Role 14 + Role 21 (advisory) |
| Week 2 | Parameter UI: Dynamic form generation, control factory, runtime selector | Role 02 |
| Week 3 | Visual builder: Canvas, nodes, connections, graph model | Role 16 |
| Week 3 | Workflow export: Nextflow/Snakemake code generation | Role 16 |
| Week 4 | Testing: Unit tests, integration tests, container runtime tests | Role 19 |
| Week 4 | Polish: Bug fixes, documentation, review | All |

---

## Deliverables Summary (UPDATED)

### Core Module (LungfishWorkflow)
1. **WorkflowRunner** - Base protocol and actor for workflow execution
2. **ProcessManager** - NSTask/Process lifecycle management
3. **NextflowRunner** - Nextflow CLI integration (UPDATED)
4. **SnakemakeRunner** - Snakemake CLI integration (UPDATED)
5. **ContainerRuntimeProtocol** - Abstract container runtime (NEW)
6. **AppleContainerRuntime** - Apple Containerization integration (NEW, PRIMARY)
7. **DockerRuntime** - Docker fallback (NEW)
8. **ContainerRuntimeFactory** - Runtime selection logic (NEW)
9. ~~ContainerRuntime~~ - DEPRECATED, migration support only
10. **WorkflowSchema** - Unified parameter schema model
11. **NextflowSchemaParser** - nf-core schema.json parsing
12. **SnakemakeConfigParser** - config.yaml parsing
13. **WorkflowGraph** - DAG data structure
14. **NextflowExporter** - Visual graph to Nextflow DSL
15. **SnakemakeExporter** - Visual graph to Snakemake

### Container Module (NEW)
1. **ContainerConfiguration** - Unified container config
2. **ContainerImage** - Image metadata model
3. **Container** - Container instance model
4. **ContainerProcess** - Process execution model
5. **ContainerLogStreamer** - Log streaming utilities

### UI Module (LungfishApp)
1. **ParameterFormView** - Dynamic form generation
2. **WorkflowCanvasView** - Node-based visual editor
3. **WorkflowNodeView** - Individual node rendering
4. **WorkflowConfigurationPanel** - Workflow settings
5. **WorkflowExecutionView** - Real-time execution monitor
6. **ContainerRuntimeSelector** - Runtime preference UI (NEW)

### Tests
1. **NextflowRunnerTests** - 20+ test cases
2. **SnakemakeRunnerTests** - 20+ test cases
3. **SchemaParserTests** - 30+ test cases
4. **WorkflowGraphTests** - 25+ test cases
5. **ContainerRuntimeFactoryTests** - 15+ test cases (NEW)
6. **AppleContainerRuntimeTests** - 20+ test cases (NEW)
7. **DockerRuntimeTests** - 15+ test cases (NEW)
8. **UI Tests** - 15+ test cases
9. **Mock Infrastructure** - Complete mocking system

---

## QA Lead Requirements (Role 19) - UPDATED

The Testing & QA Lead has established the following requirements for Phase 6:

1. **Mock-based testing** - All workflow execution must be testable without actual CLI tools
2. **Process isolation** - No actual processes spawned during unit tests
3. **Graph validation** - Cycle detection must have 100% coverage
4. **Schema parsing** - All nf-core schema features must be tested
5. **UI testing** - Parameter form generation must be unit testable
6. **Performance benchmarks** - Graph operations must handle 1000+ nodes
7. **Documentation** - All public APIs must have doc comments
8. **Code review** - All PRs require QA sign-off
9. **Container runtime testing** - Both Apple Containerization and Docker paths tested (NEW)
10. **Platform compatibility** - Tests must pass on macOS 14+ (graceful degradation for container features) (NEW)

---

## Expert Consensus (UPDATED)

All 21 experts have reviewed and approved the Phase 6 plan:

- Swift Architecture Lead (Role 01): Protocol design and actor model approved
- UI/UX Lead (Role 02): Parameter UI generation approach approved, runtime selector added
- Workflow Integration Lead (Role 14): Nextflow/Snakemake integration scope confirmed, Apple Containerization integration approved
- Visual Workflow Builder (Role 16): Node-based editor architecture approved
- Testing & QA Lead (Role 19): Testing strategy and coverage targets approved, container runtime tests added
- **Apple Containerization Expert (Role 21)**: Container runtime strategy approved, briefing document provided (NEW)

---

## Risk Assessment (UPDATED)

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| ~~Container runtime unavailable~~ | ~~Medium~~ | ~~Medium~~ | ~~Graceful degradation, local execution mode~~ |
| **No container runtime available** | Low | Medium | Graceful degradation, clear user messaging, local execution mode (UPDATED) |
| **Apple Containerization not available (older macOS)** | Medium | Low | Fall back to Docker automatically (NEW) |
| **Docker not installed as fallback** | Medium | Medium | Clear installation instructions, link to Docker Desktop (NEW) |
| Nextflow schema evolution | Low | Low | Schema version detection, fallback parsing |
| Performance with large graphs | Low | Medium | Spatial indexing, viewport culling |
| Platform-specific issues | Medium | Low | Comprehensive process management abstraction |

---

## Success Criteria (UPDATED)

Phase 6 will be considered complete when:

1. Nextflow pipelines can be executed from within Lungfish
2. Snakemake workflows can be executed from within Lungfish
3. Parameter UIs are generated from nf-core schema.json files
4. Visual workflow builder can create and edit workflows
5. Workflows can be exported to Nextflow/Snakemake code
6. **Apple Containerization is used as PRIMARY runtime on macOS 26+** (UPDATED)
7. **Docker is available as FALLBACK runtime** (UPDATED)
8. ~~Container runtime (Docker/Apptainer) is detected and used~~ REPLACED BY #6 and #7
9. All tests pass (target: 650+ tests total, increased from 600+)
10. Documentation is complete for all public APIs
11. Performance meets benchmarks (1000+ nodes, <100ms operations)
12. **Container startup time <1s with Apple Containerization** (NEW)

---

## Related Documents

- [APPLE-CONTAINERIZATION-BRIEFING.md](./APPLE-CONTAINERIZATION-BRIEFING.md) - Detailed briefing on Apple Containerization framework

---

**Meeting Conclusion:** Phase 6 plan APPROVED with Apple Containerization updates. Implementation begins immediately with Week 1 core infrastructure.

**Next Review:** 2026-02-08 (Week 1 Progress Review)

---

**Change Log:**
- 2026-02-01: Initial Phase 6 planning document created
- 2026-02-01: Updated to incorporate Apple Containerization as PRIMARY runtime per Role 21 briefing
