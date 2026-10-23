// ImageToolManifest.swift - The tools an image or a Mac replay holds, by id, version, build and absolute path (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The conda platform a manifest's tools were built for, the two names the Mac's tool lock accepts.
package enum ImageToolPlatform: String, Codable, Sendable, CaseIterable {
    case linux64 = "linux-64"
    case osxArm64 = "osx-arm64"

    /// The platform of this build, nil on a host that is neither.
    package static var current: ImageToolPlatform? {
        #if os(Linux) && arch(x86_64)
        return .linux64
        #elseif os(macOS) && arch(arm64)
        return .osxArm64
        #else
        return nil
        #endif
    }
}

/// One executable a manifest lists: a file directly under an environment's `bin/` that a conda package installed.
package struct ImageTool: Codable, Sendable, Equatable, Hashable {
    /// The file's name, such as `clumpify.sh`, `bgzip`, `pigz` or `seqkit`.
    package var id: String
    package var version: String
    package var build: String
    /// Absolute, with no empty, `.` or `..` component. Never resolved under a plan's work root.
    package var path: String
    /// The conda package whose record lists the file.
    package var condaPackage: String

    package init(id: String, version: String, build: String, path: String, condaPackage: String) {
        self.id = id
        self.version = version
        self.build = build
        self.path = path
        self.condaPackage = condaPackage
    }

    /// The pin a plan step names this tool by.
    package var pin: PlanToolPin { PlanToolPin(id: id, version: version, build: build) }
}

/// Why a tool manifest cannot be built or read, naming the field.
package struct ImageToolManifestError: Error, Equatable, CustomStringConvertible {
    package var field: String
    package var reason: String

    package init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    package var description: String { "\(field): \(reason)" }
}

/// The image's tool manifest, the one source of each tool's version and path on the node (tally K4.2, SWIFT ruling
/// Q-K4-1). The executor reads it from `imagePath` or the file `--image-manifest` names, after the plan's pin matches
/// its bytes. The image build and the Mac replay both write it with `build(condaPrefixes:)` (ARCH-r3 ruling 3).
package struct ImageToolManifest: Codable, Sendable, Equatable {
    package static let currentSchemaVersion = 1
    /// The executor's one compiled-in path, the manifest's place in a Lungfish image.
    package static let imagePath = "/opt/lungfish/image-manifest.json"
    /// The largest manifest the executor reads.
    package static let maximumSize = 1 << 20

    package var schemaVersion: Int
    package var platform: ImageToolPlatform
    package var tools: [ImageTool]

    package init(schemaVersion: Int = ImageToolManifest.currentSchemaVersion, platform: ImageToolPlatform, tools: [ImageTool]) {
        self.schemaVersion = schemaVersion
        self.platform = platform
        self.tools = tools
    }

    /// The tool the executor runs for `pin`: the first, by path, of the entries with the same id, version and build.
    package func tool(matching pin: PlanToolPin) -> ImageTool? {
        Self.sorted(tools).first { $0.pin == pin }
    }

    /// The one version and build the manifest lists for `id`, which a plan writer copies into its pin. It refuses an
    /// id the manifest lacks or lists at two versions or builds, so the writer never picks one silently.
    package func pin(forToolID id: String) throws -> PlanToolPin {
        let pins = Set(tools.filter { $0.id == id }.map(\.pin))
        guard let pin = pins.first else {
            throw ImageToolManifestError(field: "tools", reason: "The tool manifest lists no tool \(id).")
        }
        guard pins.count == 1 else {
            let listed = pins.map { "\($0.version) \($0.build)" }.sorted().joined(separator: ", ")
            throw ImageToolManifestError(field: "tools", reason: "The tool manifest lists \(id) at more than one version or build (\(listed)).")
        }
        return pin
    }

    /// The manifest file's bytes: keys sorted, tools sorted by id, version, build and path, no indentation, so the
    /// same tools given in any order give equal bytes.
    package func encoded() throws -> Data {
        var copy = self
        copy.tools = Self.sorted(tools)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(copy) + Data("\n".utf8)
    }

    /// Decodes and checks a manifest. The executor calls it on the bytes whose SHA-256 and size matched the plan's pin.
    package static func decode(_ data: Data) throws -> ImageToolManifest {
        guard data.count <= maximumSize else {
            throw ImageToolManifestError(field: "imageManifest", reason: "The tool manifest is \(data.count) bytes, over the limit of \(maximumSize).")
        }
        let manifest: ImageToolManifest
        do {
            manifest = try JSONDecoder().decode(ImageToolManifest.self, from: data)
        } catch is DecodingError {
            throw ImageToolManifestError(field: "imageManifest", reason: "The tool manifest cannot be read.")
        }
        try manifest.validate()
        return manifest
    }

    /// Checks the schema version and every tool: an id that names a file, a version and a build, an absolute path with
    /// no empty, `.` or `..` component, and no entry twice.
    package func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ImageToolManifestError(field: "schemaVersion", reason: "The tool manifest has schema version \(schemaVersion), and this build reads \(Self.currentSchemaVersion).")
        }
        var seen = Set<ImageTool>()
        for (index, tool) in tools.enumerated() {
            let field = "tools[\(index)]"
            guard Self.isFileName(tool.id) else {
                throw ImageToolManifestError(field: "\(field).id", reason: "A tool id must name one file.")
            }
            guard !tool.version.isEmpty, !tool.build.isEmpty, !tool.condaPackage.isEmpty else {
                throw ImageToolManifestError(field: field, reason: "The tool \(tool.id) has no version, build or package.")
            }
            if let reason = Self.refusal(forToolPath: tool.path) {
                throw ImageToolManifestError(field: "\(field).path", reason: reason)
            }
            guard seen.insert(tool).inserted else {
                throw ImageToolManifestError(field: field, reason: "The tool manifest lists \(tool.path) twice.")
            }
        }
    }

    /// Nil when `path` is absolute with no empty, `.` or `..` component, else the reason.
    package static func refusal(forToolPath path: String) -> String? {
        guard path.hasPrefix("/") else { return "The tool path \(path) is not absolute." }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return "The tool path \(path) holds an empty, . or .. component."
        }
        return nil
    }

    private static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func sorted(_ tools: [ImageTool]) -> [ImageTool] {
        tools.sorted { ($0.id, $0.version, $0.build, $0.path) < ($1.id, $1.version, $1.build, $1.path) }
    }
}

extension ImageToolManifest {
    /// Builds the manifest of this build's platform from conda environments (ARCH-r3 ruling 3).
    package static func build(condaPrefixes: [URL]) throws -> ImageToolManifest {
        guard let platform = ImageToolPlatform.current else {
            throw ImageToolManifestError(field: "platform", reason: "This machine is neither linux-64 nor osx-arm64.")
        }
        return try build(condaPrefixes: condaPrefixes, platform: platform)
    }

    /// Builds a manifest from each environment's `conda-meta/*.json`: every file a package record lists directly under
    /// `bin/` that is an executable regular file becomes a tool with the package's version and build and the absolute
    /// path `<prefix>/bin/<name>`. A Java under `lib/jvm/bin` counts as the prefix's `java` when `bin/` has none, as in
    /// the Mac's bbtools environment, since a BBTools wrapper finds Java through PATH (SWIFT Q-K4-3). A prefix must be absolute with no `.` or `..` component, since its paths go into the
    /// manifest as written. It refuses a prefix with no `conda-meta`, a record with no name, version or build, no tool
    /// at all, and a manifest over `maximumSize`.
    package static func build(condaPrefixes: [URL], platform: ImageToolPlatform) throws -> ImageToolManifest {
        var tools: [ImageTool] = []
        for prefixURL in condaPrefixes {
            var prefix = prefixURL.path
            while prefix.count > 1, prefix.hasSuffix("/") { prefix.removeLast() }
            if let reason = refusal(forToolPath: prefix) {
                throw ImageToolManifestError(field: "condaPrefix", reason: reason)
            }
            tools += try executables(inPrefix: prefix)
        }
        guard !tools.isEmpty else {
            throw ImageToolManifestError(field: "tools", reason: "The conda environments hold no executable under bin/.")
        }
        let manifest = ImageToolManifest(platform: platform, tools: sorted(tools))
        try manifest.validate()
        let size = try manifest.encoded().count
        guard size <= maximumSize else {
            throw ImageToolManifestError(field: "tools", reason: "The tool manifest would be \(size) bytes, over the limit of \(maximumSize).")
        }
        return manifest
    }

    private struct CondaRecord: Decodable {
        let name: String?
        let version: String?
        let build: String?
        let files: [String]?
    }

    private static func executables(inPrefix prefix: String) throws -> [ImageTool] {
        let metaFolder = prefix + "/conda-meta"
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: metaFolder)
        } catch {
            throw ImageToolManifestError(field: "condaPrefix", reason: "The environment \(prefix) has no conda-meta folder.")
        }
        var tools: [ImageTool] = []
        var jvmJava: ImageTool?
        for name in names.sorted() where name.hasSuffix(".json") {
            let recordPath = metaFolder + "/" + name
            let record: CondaRecord
            do {
                record = try JSONDecoder().decode(CondaRecord.self, from: Data(contentsOf: URL(fileURLWithPath: recordPath)))
            } catch {
                throw ImageToolManifestError(field: "condaPrefix", reason: "The package record \(recordPath) cannot be read.")
            }
            guard let package = record.name, !package.isEmpty, let version = record.version, !version.isEmpty,
                  let build = record.build, !build.isEmpty else {
                throw ImageToolManifestError(field: "condaPrefix", reason: "The package record \(recordPath) has no name, version or build.")
            }
            for file in record.files ?? [] {
                let parts = file.split(separator: "/", omittingEmptySubsequences: false)
                let isJVMJava = parts.count == 4 && parts[0] == "lib" && parts[1] == "jvm" && parts[2] == "bin" && parts[3] == "java"
                guard (parts.count == 2 && parts[0] == "bin" && isFileName(String(parts[1]))) || isJVMJava else { continue }
                let path = prefix + "/" + file
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      fileManager.isExecutableFile(atPath: path) else { continue }
                let tool = ImageTool(id: String(parts[parts.count - 1]), version: version, build: build, path: path, condaPackage: package)
                if isJVMJava { jvmJava = tool } else { tools.append(tool) }
            }
        }
        // A prefix whose Java lives only under lib/jvm/bin, as the Mac's bbtools environment does, still names its Java.
        if let jvmJava, !tools.contains(where: { $0.id == "java" }) { tools.append(jvmJava) }
        return tools
    }
}
