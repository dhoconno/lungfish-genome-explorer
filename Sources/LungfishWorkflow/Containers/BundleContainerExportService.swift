import Foundation

public struct BundleContainerExportResult: Sendable, Hashable {
    public let outputURL: URL
    public let imageDigest: String
    public let manifestDigest: String
    public let provenanceURL: URL?
}

public struct BundleContainerExportService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func export(
        bundle: URL,
        output: URL,
        pluginPacks: [PluginPack],
        commandLine: [String]
    ) async throws -> BundleContainerExportResult {
        let start = Date()
        let bundleURL = bundle.standardizedFileURL
        let outputURL = output.standardizedFileURL
        let payloadFiles = regularFiles(under: bundleURL)
        let layerEntries = try payloadFiles.map { file in
            let relative = relativePath(from: bundleURL, to: file)
            return DeterministicTarEntry(
                path: "lungfish-bundle/\(relative)",
                data: try Data(contentsOf: file)
            )
        } + [
            DeterministicTarEntry(
                path: "lungfish-plugin-packs.json",
                data: try jsonData(pluginPackManifest(pluginPacks))
            ),
        ]

        let layerTar = try tarData(entries: layerEntries)
        let layerDigest = "sha256:\(DeterministicTarWriter.sha256(layerTar))"
        let config = ociConfig(pluginPacks: pluginPacks)
        let configData = try jsonData(config)
        let configDigest = "sha256:\(DeterministicTarWriter.sha256(configData))"
        let manifest = ociManifest(
            configDigest: configDigest,
            configSize: configData.count,
            layerDigest: layerDigest,
            layerSize: layerTar.count,
            pluginPacks: pluginPacks
        )
        let manifestData = try jsonData(manifest)
        let manifestDigest = "sha256:\(DeterministicTarWriter.sha256(manifestData))"
        let index = ociIndex(manifestDigest: manifestDigest, manifestSize: manifestData.count)

        let end = Date()
        let provenanceData = try jsonData(provenance(
            bundle: bundleURL,
            payloadFiles: payloadFiles,
            output: outputURL,
            pluginPacks: pluginPacks,
            commandLine: commandLine,
            imageDigest: manifestDigest,
            configDigest: configDigest,
            configSize: configData.count,
            manifestDigest: manifestDigest,
            manifestSize: manifestData.count,
            layerDigest: layerDigest,
            layerSize: layerTar.count,
            start: start,
            end: end
        ))

        let entries = [
            DeterministicTarEntry(path: "oci-layout", data: Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)),
            DeterministicTarEntry(path: "index.json", data: try jsonData(index)),
            DeterministicTarEntry(path: "blobs/sha256/\(configDigest.dropFirst("sha256:".count))/config.json", data: configData),
            DeterministicTarEntry(path: "blobs/sha256/\(manifestDigest.dropFirst("sha256:".count))/manifest.json", data: manifestData),
            DeterministicTarEntry(path: "blobs/sha256/\(layerDigest.dropFirst("sha256:".count))/layer.tar", data: layerTar),
            DeterministicTarEntry(path: ProvenanceRecorder.provenanceFilename, data: provenanceData),
        ]
        try DeterministicTarWriter().archive(entries: entries, to: outputURL)

        return BundleContainerExportResult(
            outputURL: outputURL,
            imageDigest: manifestDigest,
            manifestDigest: manifestDigest,
            provenanceURL: nil
        )
    }

    private func regularFiles(under directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func relativePath(from base: URL, to file: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(basePath + "/") {
            return String(filePath.dropFirst(basePath.count + 1))
        }
        return file.lastPathComponent
    }

    private func tarData(entries: [DeterministicTarEntry]) throws -> Data {
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("lungfish-layer-\(UUID().uuidString).tar")
        defer { try? fileManager.removeItem(at: temp) }
        try DeterministicTarWriter().archive(entries: entries, to: temp)
        return try Data(contentsOf: temp)
    }

    private func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func pluginPackManifest(_ packs: [PluginPack]) -> [[String: String]] {
        packs.sorted { $0.id < $1.id }.flatMap { pack in
            pack.toolRequirements.map { requirement in
                [
                    "pack": pack.id,
                    "environment": requirement.environment,
                    "id": requirement.id,
                    "packages": requirement.installPackages.joined(separator: ","),
                    "version": requirement.version ?? "unknown",
                ]
            }
        }
    }

    private func ociConfig(pluginPacks: [PluginPack]) -> [String: AnyCodable] {
        [
            "architecture": .string("arm64"),
            "os": .string("linux"),
            "created": .string("1970-01-01T00:00:00Z"),
            "config": .dictionary([
                "Labels": .dictionary([
                    "org.lungfish.plugin-packs": .string(pluginPacks.map(\.id).sorted().joined(separator: ",")),
                    "org.opencontainers.image.title": .string("Lungfish bundle export"),
                ]),
            ]),
            "rootfs": .dictionary([
                "type": .string("layers"),
                "diff_ids": .array([]),
            ]),
        ]
    }

    private func ociManifest(
        configDigest: String,
        configSize: Int,
        layerDigest: String,
        layerSize: Int,
        pluginPacks: [PluginPack]
    ) -> [String: AnyCodable] {
        [
            "schemaVersion": .integer(2),
            "mediaType": .string("application/vnd.oci.image.manifest.v1+json"),
            "annotations": .dictionary([
                "org.opencontainers.image.title": .string("Lungfish bundle export"),
                "org.lungfish.plugin-packs": .string(pluginPacks.map(\.id).sorted().joined(separator: ",")),
            ]),
            "config": .dictionary([
                "mediaType": .string("application/vnd.oci.image.config.v1+json"),
                "digest": .string(configDigest),
                "size": .integer(configSize),
            ]),
            "layers": .array([
                .dictionary([
                    "mediaType": .string("application/vnd.oci.image.layer.v1.tar"),
                    "digest": .string(layerDigest),
                    "size": .integer(layerSize),
                ]),
            ]),
        ]
    }

    private func ociIndex(manifestDigest: String, manifestSize: Int) -> [String: AnyCodable] {
        [
            "schemaVersion": .integer(2),
            "manifests": .array([
                .dictionary([
                    "mediaType": .string("application/vnd.oci.image.manifest.v1+json"),
                    "digest": .string(manifestDigest),
                    "size": .integer(manifestSize),
                    "platform": .dictionary([
                        "architecture": .string("arm64"),
                        "os": .string("linux"),
                    ]),
                ]),
            ]),
        ]
    }

    private func provenance(
        bundle: URL,
        payloadFiles: [URL],
        output: URL,
        pluginPacks: [PluginPack],
        commandLine: [String],
        imageDigest: String,
        configDigest: String,
        configSize: Int,
        manifestDigest: String,
        manifestSize: Int,
        layerDigest: String,
        layerSize: Int,
        start: Date,
        end: Date
    ) -> WorkflowRun {
        let inputs = [ProvenanceRecorder.fileRecord(url: bundle, role: .input)]
            + payloadFiles.map { ProvenanceRecorder.fileRecord(url: $0, role: .input) }
        let outputRecords = [
            FileRecord(path: output.path, sha256: nil, sizeBytes: nil, format: .unknown, role: .output),
            FileRecord(path: "oci://config.json", sha256: String(configDigest.dropFirst("sha256:".count)), sizeBytes: UInt64(configSize), format: .json, role: .output),
            FileRecord(path: "oci://manifest.json", sha256: String(manifestDigest.dropFirst("sha256:".count)), sizeBytes: UInt64(manifestSize), format: .json, role: .output),
            FileRecord(path: "oci://layer.tar", sha256: String(layerDigest.dropFirst("sha256:".count)), sizeBytes: UInt64(layerSize), format: .unknown, role: .output),
        ]
        let step = StepExecution(
            toolName: "lungfish bundle export",
            toolVersion: WorkflowRun.currentAppVersion,
            containerDigest: imageDigest,
            command: CondaOfflinePackService.redactedCommandLine(commandLine),
            inputs: inputs,
            outputs: outputRecords,
            exitCode: 0,
            wallTime: end.timeIntervalSince(start),
            startTime: start,
            endTime: end
        )
        return WorkflowRun(
            name: "Bundle Container Export",
            startTime: start,
            endTime: end,
            status: .completed,
            steps: [step],
            parameters: [
                "format": .string("container"),
                "bundlePath": .string(bundle.path),
                "outputPath": .string(output.path),
                "pluginPacks": .array(pluginPacks.map(\.id).sorted().map { .string($0) }),
                "imageDigest": .string(imageDigest),
                "runtimeUser": .string(WorkflowRun.currentUser),
                "runtimeHostName": .string(ProcessInfo.processInfo.hostName),
            ]
        )
    }
}

private enum AnyCodable: Encodable {
    case string(String)
    case integer(Int)
    case array([AnyCodable])
    case dictionary([String: AnyCodable])

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .dictionary(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for key in values.keys.sorted() {
                try container.encode(values[key], forKey: DynamicCodingKey(stringValue: key))
            }
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init(intValue: Int) {
        self.stringValue = "\(intValue)"
    }
}
