// ImageManifestCommand.swift - lungfish-executor image-manifest, the tool manifest of conda environments (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `lungfish-executor image-manifest`, the image build's and the Mac replay's one way to write a tool manifest
/// (ARCH-r3 ruling 3).
///
/// Grammar: `lungfish-executor image-manifest --conda-prefix <absolute folder> [--conda-prefix <absolute folder>]...
/// [--data-file <role>=<absolute file>]... --output <file>`. A `--data-file` names a file of the image that serves a plan
/// role, the 10x barcode list as `barcodeList`. The command reads it for its SHA-256 and size and lists it under the
/// manifest's `files`. A run with no `--data-file` writes the bytes it always wrote, and a missing file, a file that is not
/// a regular file, a path that is not absolute and a role other than `barcodeList` are refused with exit 2.
/// It runs `ImageToolManifest.build(condaPrefixes:)` for this build's platform, so the image build in
/// C4 and the Mac replay write the manifest with the same code, and writes the manifest's bytes to `--output`, a file
/// that must not exist yet, created with `O_EXCL | O_NOFOLLOW` and synced. It prints one line on stdout,
/// `sha256 <hex> size <bytes> tools <count>`, the values a plan pins as `imageManifest`. Exit codes are
/// `ExecutorExitCode`: 0 written, 2 refused (a prefix the builder refuses, an unsupported platform, an output that
/// exists), 1 failed (a write error) and 64 for a usage error. A refused or failed run leaves no output file.
enum ImageManifestCommand {
    static let usage = "usage: lungfish-executor image-manifest --conda-prefix <absolute folder> [--conda-prefix <absolute folder>]... [--data-file <role>=<absolute file>]... --output <file>\n"

    /// One `--data-file <role>=<absolute file>`, split at the first `=`.
    struct DataFile: Equatable, Sendable {
        var role: String
        var path: String
    }

    struct Options: Equatable, Sendable {
        var condaPrefixes: [String] = []
        var dataFiles: [DataFile] = []
        var output = ""
    }

    struct UsageError: Error, Equatable {
        let message: String
    }

    /// Parses the arguments after `image-manifest`, or returns the usage error.
    static func parse(_ arguments: [String]) -> Result<Options, UsageError> {
        var options = Options()
        var output: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument == "--conda-prefix" || argument == "--output" || argument == "--data-file" else {
                return .failure(UsageError(message: "unknown argument \(argument)"))
            }
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                return .failure(UsageError(message: "\(argument) needs a value"))
            }
            let value = arguments[index + 1]
            if argument == "--conda-prefix" {
                options.condaPrefixes.append(value)
            } else if argument == "--data-file" {
                guard let equals = value.firstIndex(of: "="), equals != value.startIndex, value.index(after: equals) != value.endIndex else {
                    return .failure(UsageError(message: "--data-file needs <role>=<absolute file>"))
                }
                options.dataFiles.append(DataFile(role: String(value[..<equals]), path: String(value[value.index(after: equals)...])))
            } else {
                guard output == nil else { return .failure(UsageError(message: "--output is given twice")) }
                output = value
            }
            index += 2
        }
        guard !options.condaPrefixes.isEmpty else { return .failure(UsageError(message: "--conda-prefix is required")) }
        guard let output else { return .failure(UsageError(message: "--output is required")) }
        options.output = output
        return .success(options)
    }

    static func main(_ arguments: [String]) -> Int32 {
        let options: Options
        switch parse(arguments) {
        case .success(let parsed):
            options = parsed
        case .failure(let error):
            report("lungfish-executor: \(error.message)\n\(usage)")
            return ExecutorExitCode.usage
        }
        let data: Data
        do {
            // The data files come first, so a missing list is refused the same way on every host.
            let files = try options.dataFiles.map(readDataFile)
            var manifest = try ImageToolManifest.build(condaPrefixes: options.condaPrefixes.map { URL(fileURLWithPath: $0) })
            if !files.isEmpty {
                manifest.files = files
                try manifest.validate()
            }
            data = try manifest.encoded()
            guard data.count <= ImageToolManifest.maximumSize else {
                throw ImageToolManifestError(field: "files", reason: "The tool manifest would be \(data.count) bytes, over the limit of \(ImageToolManifest.maximumSize).")
            }
        } catch let error as ImageToolManifestError {
            report("lungfish-executor: image-manifest refused, \(error.field): \(error.reason)\n")
            return ExecutorExitCode.refused
        } catch {
            report("lungfish-executor: image-manifest refused, the manifest could not be encoded. \(error)\n")
            return ExecutorExitCode.refused
        }
        let descriptor = open(options.output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            report("lungfish-executor: image-manifest refused, cannot create \(options.output). \(String(cString: strerror(code)))\n")
            return code == EEXIST || code == ELOOP ? ExecutorExitCode.refused : ExecutorExitCode.failed
        }
        if let failure = writeWhole(data, to: descriptor) {
            close(descriptor)
            unlink(options.output)
            report("lungfish-executor: image-manifest failed writing \(options.output). \(failure)\n")
            return ExecutorExitCode.failed
        }
        close(descriptor)
        let line = "sha256 \(PortableDigest.sha256Hex(of: data)) size \(data.count) tools \(toolCount(data))\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        return ExecutorExitCode.succeeded
    }

    /// The manifest entry of one `--data-file`, with the SHA-256 and size of a regular file at an absolute path. The only role
    /// an image data file serves today is `barcodeList`.
    private static func readDataFile(_ file: DataFile) throws -> ImageDataFile {
        guard file.role == PlanEntryRole.barcodeList.rawValue else {
            throw ImageToolManifestError(field: "dataFile", reason: "The role \(file.role) is not one an image data file serves. The only role is \(PlanEntryRole.barcodeList.rawValue).")
        }
        if let reason = ImageToolManifest.refusal(forToolPath: file.path) {
            throw ImageToolManifestError(field: "dataFile", reason: reason.replacingOccurrences(of: "The tool path", with: "The data file path"))
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw ImageToolManifestError(field: "dataFile", reason: "The data file \(file.path) is not a regular file that can be read.")
        }
        guard let digest = try? PortableDigest.sha256Hex(ofFileAt: URL(fileURLWithPath: file.path)) else {
            throw ImageToolManifestError(field: "dataFile", reason: "The data file \(file.path) cannot be read.")
        }
        return ImageDataFile(path: file.path, role: file.role, sha256: digest, size: size)
    }

    /// Writes every byte and syncs, or returns the reason.
    private static func writeWhole(_ data: Data, to descriptor: Int32) -> String? {
        let failure: String? = data.withUnsafeBytes { buffer -> String? in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return String(cString: strerror(errno))
                }
                offset += written
            }
            return nil
        }
        if let failure { return failure }
        return fsync(descriptor) == 0 ? nil : String(cString: strerror(errno))
    }

    private static func toolCount(_ data: Data) -> Int {
        (try? ImageToolManifest.decode(data))?.tools.count ?? 0
    }

    private static func report(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
}
