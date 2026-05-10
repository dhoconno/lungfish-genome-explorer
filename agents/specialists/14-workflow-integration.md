# Role: Workflow Integration Lead

## Responsibilities

### Primary Duties
- Implement Nextflow runner with native execution
- Build Snakemake runner with native execution
- Create schema parsing for automatic UI generation
- Design workflow output capture and import
- Integrate Docker/Apptainer container orchestration

### Key Deliverables
- Nextflow execution engine with DSL2 support
- Snakemake execution engine
- Dynamic parameter UI from workflow schemas
- Workflow progress monitoring
- nf-core pipeline integration
- Container runtime management

### Decision Authority
- Workflow execution strategy
- Schema parsing approach
- Container runtime selection
- Output format handling
- Progress monitoring implementation

---

## Technical Scope

### Technologies/Frameworks Owned
- Nextflow runner
- Snakemake runner
- Workflow schema parsing (nextflow_schema.json)
- Container orchestration (Docker, Apptainer)
- Process management

### Component Ownership
```
LungfishWorkflow/
├── Nextflow/
│   ├── NextflowRunner.swift          # PRIMARY OWNER
│   ├── NextflowConfig.swift          # PRIMARY OWNER
│   ├── NextflowSchemaParser.swift    # PRIMARY OWNER
│   └── NFCoreIntegration.swift       # PRIMARY OWNER
├── Snakemake/
│   ├── SnakemakeRunner.swift         # PRIMARY OWNER
│   ├── SnakemakeConfig.swift         # PRIMARY OWNER
│   └── SnakemakeParser.swift         # PRIMARY OWNER
├── Container/
│   ├── ContainerRuntime.swift        # PRIMARY OWNER
│   ├── DockerManager.swift           # PRIMARY OWNER
│   └── ApptainerManager.swift        # PRIMARY OWNER
├── Common/
│   ├── WorkflowProtocol.swift        # PRIMARY OWNER
│   ├── WorkflowProgress.swift        # PRIMARY OWNER
│   └── OutputImporter.swift          # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── Workflow/
│   │   ├── WorkflowRunnerView.swift  # PRIMARY OWNER
│   │   ├── ParameterFormView.swift   # PRIMARY OWNER
│   │   ├── WorkflowProgressView.swift # PRIMARY OWNER
│   │   └── NFCoreBrowserView.swift   # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Plugin Architect | Workflow as plugin type |
| Visual Workflow Builder | Execution of visual workflows |
| File Format Expert | Output file handling |
| Storage Lead | Workflow results storage |

---

## Key Decisions to Make

### Architectural Choices

1. **Execution Environment**
   - Local vs. remote vs. hybrid
   - Recommendation: Local primary with optional remote profile

2. **Container Priority**
   - Docker vs. Apptainer vs. user choice
   - Recommendation: Detect available, prefer Docker on macOS

3. **Schema Handling**
   - Dynamic form generation vs. template forms
   - Recommendation: Dynamic from nextflow_schema.json

4. **Output Handling**
   - Auto-import vs. manual selection
   - Recommendation: Auto-suggest with user confirmation

### Workflow Configuration
```swift
public struct WorkflowConfig {
    // Execution settings
    public var executor: Executor = .local
    public var containerRuntime: ContainerRuntime = .docker
    public var workDir: URL

    // Resource limits
    public var maxCpus: Int = ProcessInfo.processInfo.activeProcessorCount
    public var maxMemory: String = "16.GB"
    public var maxTime: String = "24.h"

    // Profiles
    public var profiles: [String] = ["docker"]

    // Resume
    public var resume: Bool = false
    public var sessionId: String?

    public enum Executor: String {
        case local
        case awsbatch
        case googlebatch
        case slurm
    }
}
```

---

## Success Criteria

### Performance Targets
- Workflow launch: < 5 seconds
- Progress update frequency: Every 5 seconds
- Schema parsing: < 500ms
- Output import: < 1 second per file

### Quality Metrics
- Workflow execution success rate matches CLI
- Parameter validation matches schema
- Container pull success rate > 99%
- Progress accuracy within 10%

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 4 | Container runtime detection | Week 9 |
| 5 | Nextflow runner | Week 11 |
| 5 | Schema parser | Week 12 |
| 5 | Parameter UI generator | Week 13 |
| 6 | Snakemake runner | Week 14 |
| 6 | nf-core integration | Week 15 |

---

## Reference Materials

### Nextflow Documentation
- [Nextflow Documentation](https://www.nextflow.io/docs/latest/index.html)
- [Nextflow Schema](https://nextflow-io.github.io/nf-schema/)
- [nf-core Pipelines](https://nf-co.re/pipelines)

### Snakemake Documentation
- [Snakemake Documentation](https://snakemake.readthedocs.io/)
- [Snakemake Wrappers](https://snakemake-wrappers.readthedocs.io/)

### Container Documentation
- [Docker Engine API](https://docs.docker.com/engine/api/)
- [Apptainer Documentation](https://apptainer.org/docs/)

---

## Technical Specifications

### Workflow Protocol
```swift
public protocol WorkflowRunner {
    associatedtype Config: WorkflowConfig
    associatedtype Schema: WorkflowSchema

    var isAvailable: Bool { get async }
    var version: String { get async throws }

    func parseSchema(from url: URL) async throws -> Schema
    func run(
        workflow: URL,
        config: Config,
        parameters: [String: Any],
        progress: @escaping (WorkflowProgress) -> Void
    ) async throws -> WorkflowResult

    func cancel() async
    func resume(sessionId: String) async throws -> WorkflowResult
}

public struct WorkflowProgress {
    public let phase: Phase
    public let message: String
    public let tasksCompleted: Int
    public let tasksTotal: Int
    public let currentTask: String?
    public let percentage: Double

    public enum Phase {
        case preparing
        case pullingContainers
        case running
        case finishing
        case completed
        case failed
    }
}

public struct WorkflowResult {
    public let success: Bool
    public let sessionId: String
    public let workDir: URL
    public let outputs: [WorkflowOutput]
    public let logs: URL
    public let duration: TimeInterval
    public let errorMessage: String?
}

public struct WorkflowOutput {
    public let path: URL
    public let type: OutputType
    public let suggested: Bool  // Auto-import suggestion

    public enum OutputType {
        case sequence(format: String)
        case alignment(format: String)
        case annotation(format: String)
        case report(format: String)
        case other
    }
}
```

### Nextflow Runner
```swift
public actor NextflowRunner: WorkflowRunner {
    private let nextflowPath: URL
    private let containerManager: ContainerManager
    private var currentProcess: Process?

    public var isAvailable: Bool {
        get async {
            FileManager.default.fileExists(atPath: nextflowPath.path)
        }
    }

    public var version: String {
        get async throws {
            let output = try await runCommand([nextflowPath.path, "-version"])
            // Parse version from output
            return parseVersion(output)
        }
    }

    public func parseSchema(from url: URL) async throws -> NextflowSchema {
        // Look for nextflow_schema.json
        let schemaPath = url.deletingLastPathComponent().appending(path: "nextflow_schema.json")

        guard FileManager.default.fileExists(atPath: schemaPath.path) else {
            // Fall back to parsing main.nf for params
            return try parseParamsFromWorkflow(url)
        }

        let data = try Data(contentsOf: schemaPath)
        return try JSONDecoder().decode(NextflowSchema.self, from: data)
    }

    public func run(
        workflow: URL,
        config: NextflowConfig,
        parameters: [String: Any],
        progress: @escaping (WorkflowProgress) -> Void
    ) async throws -> WorkflowResult {
        // Build command
        var args = [nextflowPath.path, "run", workflow.path]

        // Add profiles
        if !config.profiles.isEmpty {
            args += ["-profile", config.profiles.joined(separator: ",")]
        }

        // Add work directory
        args += ["-work-dir", config.workDir.path]

        // Add resume if enabled
        if config.resume, let sessionId = config.sessionId {
            args += ["-resume", sessionId]
        }

        // Add parameters
        for (key, value) in parameters {
            args += ["--\(key)", String(describing: value)]
        }

        // Add resource limits
        args += [
            "-process.cpus", String(config.maxCpus),
            "-process.memory", config.maxMemory
        ]

        // Create process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = workflow.deletingLastPathComponent()

        // Set up output capture
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Track progress from output
        let progressTask = Task {
            for try await line in outputPipe.fileHandleForReading.bytes.lines {
                if let progressUpdate = parseNextflowProgress(line) {
                    progress(progressUpdate)
                }
            }
        }

        currentProcess = process
        let startTime = Date()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw WorkflowError.executionFailed(error)
        }

        progressTask.cancel()
        currentProcess = nil

        let success = process.terminationStatus == 0

        // Collect outputs
        let outputs = try await collectOutputs(workDir: config.workDir)

        return WorkflowResult(
            success: success,
            sessionId: extractSessionId(from: config.workDir),
            workDir: config.workDir,
            outputs: outputs,
            logs: config.workDir.appending(path: ".nextflow.log"),
            duration: Date().timeIntervalSince(startTime),
            errorMessage: success ? nil : try? String(contentsOf: errorPipe.fileHandleForReading)
        )
    }

    public func cancel() async {
        currentProcess?.terminate()
        currentProcess = nil
    }

    private func parseNextflowProgress(_ line: String) -> WorkflowProgress? {
        // Parse Nextflow output for progress
        // Example: "executor >  local (5), process > FASTQC (3), status: 60% (3/5)"

        if line.contains("executor >") {
            // Extract counts
            if let match = line.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
                let parts = line[match].split(separator: "/")
                let completed = Int(parts[0]) ?? 0
                let total = Int(parts[1]) ?? 1
                return WorkflowProgress(
                    phase: .running,
                    message: line,
                    tasksCompleted: completed,
                    tasksTotal: total,
                    currentTask: nil,
                    percentage: Double(completed) / Double(total)
                )
            }
        }

        return nil
    }
}
```

### Container Manager
```swift
public actor ContainerManager {
    public enum Runtime: String, CaseIterable {
        case docker
        case apptainer
        case singularity
        case podman

        var command: String {
            switch self {
            case .docker: return "docker"
            case .apptainer: return "apptainer"
            case .singularity: return "singularity"
            case .podman: return "podman"
            }
        }
    }

    private var availableRuntimes: [Runtime] = []

    public func detectRuntimes() async -> [Runtime] {
        var available: [Runtime] = []

        for runtime in Runtime.allCases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [runtime.command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    available.append(runtime)
                }
            } catch {
                continue
            }
        }

        availableRuntimes = available
        return available
    }

    public func pullImage(name: String, runtime: Runtime, progress: @escaping (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [runtime.command, "pull", name]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Parse pull progress
        for try await line in pipe.fileHandleForReading.bytes.lines {
            if let pct = parsePullProgress(line, runtime: runtime) {
                progress(pct)
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ContainerError.pullFailed(name)
        }
    }

    public func run(
        image: String,
        command: [String],
        volumes: [VolumeMount],
        runtime: Runtime
    ) async throws -> String {
        var args = [runtime.command, "run", "--rm"]

        // Add volume mounts
        for mount in volumes {
            args += ["-v", "\(mount.host.path):\(mount.container)"]
        }

        args += [image]
        args += command

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        return try String(contentsOf: pipe.fileHandleForReading)
    }

    public struct VolumeMount {
        public let host: URL
        public let container: String
        public let readOnly: Bool
    }
}
```

### Parameter Form Generator
```swift
public struct ParameterFormView: View {
    public let schema: NextflowSchema
    @Binding public var values: [String: Any]

    public var body: some View {
        Form {
            ForEach(schema.definitions.sorted(by: { $0.key < $1.key }), id: \.key) { groupName, group in
                Section(header: Text(group.title ?? groupName)) {
                    if let description = group.description {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ForEach(group.properties.sorted(by: { $0.key < $1.key }), id: \.key) { paramName, param in
                        parameterField(name: paramName, param: param)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func parameterField(name: String, param: SchemaParameter) -> some View {
        switch param.type {
        case "string":
            if let enumValues = param.enum {
                Picker(param.title ?? name, selection: binding(for: name, default: param.default ?? "")) {
                    ForEach(enumValues, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
            } else {
                TextField(param.title ?? name, text: binding(for: name, default: param.default ?? ""))
            }

        case "integer":
            TextField(
                param.title ?? name,
                value: binding(for: name, default: param.default ?? 0),
                format: .number
            )

        case "number":
            TextField(
                param.title ?? name,
                value: binding(for: name, default: param.default ?? 0.0),
                format: .number
            )

        case "boolean":
            Toggle(param.title ?? name, isOn: binding(for: name, default: param.default ?? false))

        default:
            TextField(param.title ?? name, text: binding(for: name, default: ""))
        }
    }

    private func binding<T>(for key: String, default defaultValue: T) -> Binding<T> {
        Binding(
            get: { values[key] as? T ?? defaultValue },
            set: { values[key] = $0 }
        )
    }
}
```

### nf-core Integration
```swift
public actor NFCoreClient {
    private let baseURL = "https://nf-co.re"
    private let session: URLSession

    public struct Pipeline: Codable, Identifiable {
        public let name: String
        public let description: String
        public let topics: [String]
        public let stargazersCount: Int
        public let releases: [Release]

        public var id: String { name }

        public struct Release: Codable {
            public let tagName: String
            public let publishedAt: Date
        }
    }

    public func listPipelines() async throws -> [Pipeline] {
        let url = URL(string: "\(baseURL)/pipelines.json")!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode([Pipeline].self, from: data)
    }

    public func getPipeline(name: String) async throws -> Pipeline {
        let url = URL(string: "\(baseURL)/\(name)/releases.json")!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(Pipeline.self, from: data)
    }

    public func launchPipeline(
        name: String,
        version: String,
        parameters: [String: Any],
        config: WorkflowConfig
    ) async throws -> WorkflowResult {
        let runner = NextflowRunner()

        // nf-core pipelines are run as: nextflow run nf-core/<name> -r <version>
        let workflowURL = URL(string: "nf-core/\(name)")!

        var params = parameters
        params["outdir"] = config.workDir.path

        return try await runner.run(
            workflow: workflowURL,
            config: config as! NextflowConfig,
            parameters: params
        ) { progress in
            // Handle progress
        }
    }
}
```
