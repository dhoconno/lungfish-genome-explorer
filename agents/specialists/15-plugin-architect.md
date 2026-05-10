# Role: Plugin Architecture Lead

## Responsibilities

### Primary Duties
- Design multi-language plugin system (Python, Rust, Swift, CLI)
- Implement PythonKit integration for Python plugins
- Build Swift-Rust FFI for high-performance plugins
- Create plugin sandboxing and security model
- Develop plugin SDK for all supported languages

### Key Deliverables
- Plugin host architecture
- Python runtime integration via PythonKit
- Rust FFI bridge with C ABI
- Swift native plugin loader
- CLI tool wrapper manifest system
- Plugin discovery and lifecycle management
- Plugin SDK packages for all languages

### Decision Authority
- Plugin API design
- Security model and sandboxing approach
- Language binding strategies
- Plugin distribution format
- Version compatibility policies

---

## Technical Scope

### Technologies/Frameworks Owned
- PythonKit (Python embedding)
- Swift-Rust FFI via C ABI
- Dynamic library loading
- Process isolation
- Plugin manifest formats

### Component Ownership
```
LungfishPlugin/
├── Host/
│   ├── PluginHost.swift              # PRIMARY OWNER
│   ├── PluginLifecycle.swift         # PRIMARY OWNER
│   ├── PluginSandbox.swift           # PRIMARY OWNER
│   └── PluginRegistry.swift          # PRIMARY OWNER
├── Python/
│   ├── PythonBridge.swift            # PRIMARY OWNER
│   ├── PythonPluginLoader.swift      # PRIMARY OWNER
│   └── PythonEnvironment.swift       # PRIMARY OWNER
├── Rust/
│   ├── RustFFI.swift                 # PRIMARY OWNER
│   ├── RustPluginLoader.swift        # PRIMARY OWNER
│   └── RustTypeConversion.swift      # PRIMARY OWNER
├── Swift/
│   ├── SwiftPluginLoader.swift       # PRIMARY OWNER
│   └── SwiftPluginBundle.swift       # PRIMARY OWNER
├── CLI/
│   ├── CLIWrapper.swift              # PRIMARY OWNER
│   ├── CLIManifestParser.swift       # PRIMARY OWNER
│   └── CLIProcessManager.swift       # PRIMARY OWNER
├── Protocols/
│   ├── PluginProtocol.swift          # PRIMARY OWNER
│   ├── SequenceOperationPlugin.swift # PRIMARY OWNER
│   ├── AnnotationPlugin.swift        # PRIMARY OWNER
│   ├── ViewerPlugin.swift            # PRIMARY OWNER
│   ├── FormatPlugin.swift            # PRIMARY OWNER
│   └── WorkflowPlugin.swift          # PRIMARY OWNER
└── SDK/
    ├── swift/                        # Swift SDK package
    ├── python/                       # Python SDK package
    └── rust/                         # Rust SDK crate
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Swift Architecture Lead | Plugin host integration |
| Bioinformatics Architect | Operation protocols |
| Workflow Integration Lead | Workflow plugin type |
| UI/UX Lead | Plugin UI integration |

---

## Key Decisions to Make

### Architectural Choices

1. **Python Integration**
   - PythonKit vs. subprocess vs. gRPC
   - Recommendation: PythonKit for tight integration, subprocess fallback

2. **Rust Integration**
   - C ABI vs. Swift-Rust bridge crate
   - Recommendation: C ABI for simplicity and stability

3. **Sandboxing**
   - Full sandbox vs. permission-based vs. trust model
   - Recommendation: Permission-based with code signing for trusted

4. **Plugin Distribution**
   - Single file vs. bundle vs. package manager
   - Recommendation: Bundle format with manifest.json

### Plugin Configuration
```swift
public struct PluginConfiguration: Codable {
    // Identity
    public let identifier: String
    public let name: String
    public let version: String
    public let author: String

    // Type and language
    public let pluginType: PluginType
    public let language: PluginLanguage

    // Capabilities
    public let capabilities: [PluginCapability]
    public let permissions: [PluginPermission]

    // Dependencies
    public let minimumAppVersion: String
    public let dependencies: [PluginDependency]

    // Entry points
    public let entryPoint: String  // Main file/function
    public let exports: [String]   // Exported functions

    public enum PluginType: String, Codable {
        case sequenceOperation
        case annotationGenerator
        case viewer
        case format
        case database
        case workflow
        case assembler
        case aligner
    }

    public enum PluginLanguage: String, Codable {
        case swift
        case python
        case rust
        case cli
    }
}
```

---

## Success Criteria

### Performance Targets
- Plugin load time: < 500ms
- Python call overhead: < 10ms
- Rust call overhead: < 1ms
- CLI execution: < 100ms startup

### Quality Metrics
- Plugin isolation: No crashes affect host
- Memory safety: Proper cleanup on unload
- API compatibility: Semantic versioning enforced
- Security: Sandboxed by default

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 3 | Plugin protocols | Week 7 |
| 3 | Plugin host architecture | Week 8 |
| 4 | Swift plugin loader | Week 9 |
| 4 | Python bridge (PythonKit) | Week 10 |
| 5 | Rust FFI bridge | Week 11 |
| 5 | CLI wrapper system | Week 12 |
| 6 | Plugin SDK packages | Week 14 |

---

## Reference Materials

### Apple Documentation
- [Creating a Mac Bundle](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/)
- [Dynamic Library Loading](https://developer.apple.com/documentation/system/dyld)
- [App Sandbox](https://developer.apple.com/documentation/security/app_sandbox)

### PythonKit
- [PythonKit GitHub](https://github.com/pvieito/PythonKit)

### Rust FFI
- [Rust FFI Omnibus](https://jakegoulding.com/rust-ffi-omnibus/)
- [cbindgen](https://github.com/eqrion/cbindgen)

---

## Technical Specifications

### Plugin Protocol
```swift
public protocol Plugin: AnyObject {
    static var identifier: String { get }
    static var name: String { get }
    static var version: String { get }
    static var pluginType: PluginType { get }

    init()
    func activate() async throws
    func deactivate() async
}

public protocol SequenceOperationPlugin: Plugin {
    var inputTypes: [SequenceAlphabet] { get }
    var outputType: SequenceAlphabet { get }
    var operationName: String { get }
    var operationDescription: String { get }
    var parameters: [OperationParameter] { get }

    func execute(
        sequences: [Sequence],
        parameters: [String: Any]
    ) async throws -> OperationResult
}

public protocol AnnotationGeneratorPlugin: Plugin {
    var annotationType: AnnotationType { get }
    var targetTypes: [SequenceAlphabet] { get }

    func generateAnnotations(
        for sequence: Sequence,
        parameters: [String: Any]
    ) async throws -> [SequenceAnnotation]
}

public protocol ViewerPlugin: Plugin {
    var supportedDocumentTypes: [DocumentType] { get }

    func createView(for document: GenomicDocument) -> NSView
    func updateView(_ view: NSView, for document: GenomicDocument)
}

public protocol FormatPlugin: Plugin {
    var supportedExtensions: [String] { get }
    var canRead: Bool { get }
    var canWrite: Bool { get }

    func read(from url: URL) async throws -> [GenomicDocument]
    func write(_ documents: [GenomicDocument], to url: URL) async throws
}
```

### Plugin Host
```swift
public actor PluginHost {
    public static let shared = PluginHost()

    private var loadedPlugins: [String: any Plugin] = [:]
    private var pythonBridge: PythonBridge?
    private var rustPlugins: [String: RustPluginHandle] = [:]

    private let pluginSearchPaths: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Lungfish/Plugins"),
        Bundle.main.builtInPlugInsURL!
    ]

    public func discoverPlugins() async throws -> [PluginConfiguration] {
        var discovered: [PluginConfiguration] = []

        for searchPath in pluginSearchPaths {
            guard FileManager.default.fileExists(atPath: searchPath.path) else { continue }

            let contents = try FileManager.default.contentsOfDirectory(
                at: searchPath,
                includingPropertiesForKeys: [.isDirectoryKey]
            )

            for item in contents {
                if item.pathExtension == "lungfishplugin" {
                    if let config = try? loadManifest(from: item) {
                        discovered.append(config)
                    }
                } else if item.pathExtension == "py" {
                    if let config = try? parsePythonPlugin(at: item) {
                        discovered.append(config)
                    }
                } else if item.pathExtension == "dylib" {
                    if let config = try? parseRustPlugin(at: item) {
                        discovered.append(config)
                    }
                } else if item.pathExtension == "yaml" || item.pathExtension == "yml" {
                    if let config = try? parseCLIManifest(at: item) {
                        discovered.append(config)
                    }
                }
            }
        }

        return discovered
    }

    public func loadPlugin(_ config: PluginConfiguration) async throws -> any Plugin {
        if let existing = loadedPlugins[config.identifier] {
            return existing
        }

        let plugin: any Plugin

        switch config.language {
        case .swift:
            plugin = try await loadSwiftPlugin(config)
        case .python:
            plugin = try await loadPythonPlugin(config)
        case .rust:
            plugin = try await loadRustPlugin(config)
        case .cli:
            plugin = try await loadCLIPlugin(config)
        }

        try await plugin.activate()
        loadedPlugins[config.identifier] = plugin

        return plugin
    }

    public func unloadPlugin(_ identifier: String) async {
        guard let plugin = loadedPlugins[identifier] else { return }

        await plugin.deactivate()
        loadedPlugins.removeValue(forKey: identifier)
    }
}
```

### Python Bridge
```swift
import PythonKit

public actor PythonBridge {
    private let python: PythonObject
    private var loadedModules: [String: PythonObject] = [:]

    public init() throws {
        // Initialize Python
        PythonLibrary.useLibrary(at: "/usr/local/bin/python3")
        python = Python.import("sys")

        // Add plugin paths to sys.path
        let pluginPath = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Lungfish/Plugins")
        python.path.append(pluginPath.path)

        // Import lungfish SDK
        _ = Python.import("lungfish")
    }

    public func loadPlugin(at path: URL) throws -> PythonPluginWrapper {
        let moduleName = path.deletingPathExtension().lastPathComponent

        // Import the module
        let module = Python.import(moduleName)

        // Find plugin class
        let pluginClass = module.__dict__.items().filter { item in
            let key = String(item.0) ?? ""
            let value = item.1
            return key != "Plugin" && Python.isinstance(value, Python.type) == true
        }.first?.1

        guard let cls = pluginClass else {
            throw PluginError.noPluginClassFound(path)
        }

        // Instantiate
        let instance = cls()

        loadedModules[moduleName] = instance

        return PythonPluginWrapper(instance: instance, module: module)
    }

    public func execute(
        plugin: PythonPluginWrapper,
        method: String,
        args: [Any]
    ) async throws -> Any {
        // Convert Swift types to Python
        let pythonArgs = args.map { convertToPython($0) }

        // Call method
        let result = plugin.instance[dynamicMember: method].call(pythonArgs)

        // Convert result back to Swift
        return try convertToSwift(result)
    }

    private func convertToPython(_ value: Any) -> PythonObject {
        switch value {
        case let s as String:
            return PythonObject(s)
        case let i as Int:
            return PythonObject(i)
        case let d as Double:
            return PythonObject(d)
        case let b as Bool:
            return PythonObject(b)
        case let seq as Sequence:
            return PythonObject(seq.sequenceString)
        case let arr as [Any]:
            return PythonObject(arr.map { convertToPython($0) })
        default:
            return Python.None
        }
    }

    private func convertToSwift(_ value: PythonObject) throws -> Any {
        if Python.isinstance(value, Python.str) == true {
            return String(value)!
        } else if Python.isinstance(value, Python.int) == true {
            return Int(value)!
        } else if Python.isinstance(value, Python.float) == true {
            return Double(value)!
        } else if Python.isinstance(value, Python.bool) == true {
            return Bool(value)!
        } else if Python.isinstance(value, Python.list) == true {
            return Array(value)!.map { try! convertToSwift($0) }
        }
        throw PluginError.unsupportedReturnType
    }
}

public struct PythonPluginWrapper {
    let instance: PythonObject
    let module: PythonObject
}
```

### Rust FFI Bridge
```swift
public final class RustPluginLoader {
    private var loadedLibraries: [String: UnsafeMutableRawPointer] = [:]

    public func loadPlugin(at path: URL) throws -> RustPluginHandle {
        // Load dynamic library
        guard let handle = dlopen(path.path, RTLD_NOW | RTLD_LOCAL) else {
            let error = String(cString: dlerror())
            throw PluginError.libraryLoadFailed(error)
        }

        loadedLibraries[path.path] = handle

        // Look up required symbols
        guard let namePtr = dlsym(handle, "plugin_name"),
              let versionPtr = dlsym(handle, "plugin_version"),
              let createPtr = dlsym(handle, "plugin_create"),
              let destroyPtr = dlsym(handle, "plugin_destroy") else {
            let error = String(cString: dlerror())
            dlclose(handle)
            throw PluginError.symbolNotFound(error)
        }

        // Get name and version
        typealias StringFunc = @convention(c) () -> UnsafePointer<CChar>
        let getName = unsafeBitCast(namePtr, to: StringFunc.self)
        let getVersion = unsafeBitCast(versionPtr, to: StringFunc.self)

        let name = String(cString: getName())
        let version = String(cString: getVersion())

        // Create plugin instance
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let create = unsafeBitCast(createPtr, to: CreateFunc.self)
        let instance = create()

        typealias DestroyFunc = @convention(c) (UnsafeMutableRawPointer) -> Void
        let destroy = unsafeBitCast(destroyPtr, to: DestroyFunc.self)

        return RustPluginHandle(
            name: name,
            version: version,
            handle: handle,
            instance: instance,
            destroy: destroy
        )
    }

    public func callFunction<T>(
        plugin: RustPluginHandle,
        name: String,
        args: UnsafeRawPointer?,
        resultType: T.Type
    ) throws -> T {
        guard let funcPtr = dlsym(plugin.handle, name) else {
            throw PluginError.functionNotFound(name)
        }

        typealias Func = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer
        let function = unsafeBitCast(funcPtr, to: Func.self)

        let result = function(plugin.instance, args)
        return result.assumingMemoryBound(to: T.self).pointee
    }

    deinit {
        for (_, handle) in loadedLibraries {
            dlclose(handle)
        }
    }
}

public struct RustPluginHandle {
    let name: String
    let version: String
    let handle: UnsafeMutableRawPointer
    let instance: UnsafeMutableRawPointer
    let destroy: (UnsafeMutableRawPointer) -> Void

    deinit {
        destroy(instance)
    }
}
```

### CLI Wrapper
```swift
public struct CLIPluginWrapper: SequenceOperationPlugin {
    public let manifest: CLIManifest

    public static var identifier: String { "" }  // Set from manifest
    public static var name: String { "" }
    public static var version: String { "" }
    public static var pluginType: PluginType { .sequenceOperation }

    public var inputTypes: [SequenceAlphabet] { manifest.inputTypes }
    public var outputType: SequenceAlphabet { manifest.outputType }
    public var operationName: String { manifest.name }
    public var operationDescription: String { manifest.description }
    public var parameters: [OperationParameter] { manifest.parameters }

    public init() {
        fatalError("Use init(manifest:)")
    }

    public init(manifest: CLIManifest) {
        self.manifest = manifest
    }

    public func activate() async throws {
        // Verify command exists
        guard FileManager.default.fileExists(atPath: manifest.command) ||
              (try? await which(manifest.command)) != nil else {
            throw PluginError.commandNotFound(manifest.command)
        }
    }

    public func deactivate() async {}

    public func execute(
        sequences: [Sequence],
        parameters: [String: Any]
    ) async throws -> OperationResult {
        // Create temp files for input/output
        let inputFile = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".fasta")
        let outputFile = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + "." + manifest.outputFormat)

        // Write input sequences
        let writer = FASTAWriter()
        try writer.write(sequences, to: inputFile)

        // Build command
        var args = manifest.baseArgs
        for input in manifest.inputs {
            if input.name == "input" {
                args.append(input.flag)
                args.append(inputFile.path)
            } else if input.name == "output" {
                args.append(input.flag)
                args.append(outputFile.path)
            }
        }

        // Add parameters
        for (key, value) in parameters {
            if let param = manifest.parameters.first(where: { $0.name == key }) {
                args.append(param.flag)
                args.append(String(describing: value))
            }
        }

        // Execute
        let process = Process()
        if let containerImage = manifest.container {
            // Run in container
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
            process.arguments = ["run", "--rm",
                                 "-v", "\(inputFile.deletingLastPathComponent().path):/data",
                                 containerImage] + args
        } else {
            process.executableURL = URL(fileURLWithPath: manifest.command)
            process.arguments = args
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PluginError.executionFailed(process.terminationStatus)
        }

        // Read output
        let reader = FormatRegistry.shared.reader(for: outputFile)
        let results = try await reader.read(from: outputFile)

        // Cleanup
        try? FileManager.default.removeItem(at: inputFile)
        try? FileManager.default.removeItem(at: outputFile)

        return OperationResult(
            sequences: results.map { $0.sequence },
            annotations: results.flatMap { $0.annotations }
        )
    }
}

public struct CLIManifest: Codable {
    public let name: String
    public let version: String
    public let description: String
    public let command: String
    public let container: String?
    public let baseArgs: [String]
    public let inputs: [CLIInput]
    public let outputs: [CLIOutput]
    public let parameters: [CLIParameter]
    public let inputTypes: [SequenceAlphabet]
    public let outputType: SequenceAlphabet
    public let outputFormat: String

    public struct CLIInput: Codable {
        public let name: String
        public let type: String
        public let flag: String
    }

    public struct CLIOutput: Codable {
        public let name: String
        public let type: String
        public let format: String
        public let flag: String
    }

    public struct CLIParameter: Codable {
        public let name: String
        public let type: String
        public let flag: String
        public let `default`: AnyCodable?
        public let description: String?
    }
}
```
