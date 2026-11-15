// RunPreflight.swift - The files run --plan reads before any tool, and what it observes of the machine (CHTC lane K4)
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

/// The plan file, the running binary and the tool manifest, each opened once and read through the descriptor `fstat`
/// checked.
enum RunFiles {
    enum ReadError: Error, Equatable {
        case missing
        case notRegularFile
        case tooLarge(Int64)
        case system(Int32)

        /// The end of a sentence that begins with the file's name.
        var phrase: String {
            switch self {
            case .missing: return "is missing."
            case .notRegularFile: return "is not a regular file."
            case .tooLarge(let size): return "is \(size) bytes, over the limit."
            case .system(let code): return "cannot be read. \(String(cString: strerror(code)))"
            }
        }
    }

    /// Opens `path` once, read-only and close-on-exec, checks with `fstat` that it is a regular file of at most `limit`
    /// bytes, and reads it whole through the same descriptor. The path is never opened again.
    static func readWhole(_ path: String, limit: Int) throws(ReadError) -> Data {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            throw code == ENOENT ? ReadError.missing : ReadError.system(code)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw ReadError.system(errno) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw ReadError.notRegularFile }
        guard Int64(status.st_size) <= Int64(limit) else { throw ReadError.tooLarge(Int64(status.st_size)) }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw ReadError.system(EIO)
        }
        guard data.count <= limit else { throw ReadError.tooLarge(Int64(data.count)) }
        return data
    }

    /// The SHA-256 and size of the running binary, `/proc/self/exe` on Linux and elsewhere the real path of
    /// `CommandLine.arguments[0]` through `realpath` (tally K4.4).
    /// A launch by bare name, an `argv[0]` with no `/`, has no path to resolve, so the self-check refuses it.
    static func runningExecutorDigest() -> (sha256: String, size: Int64)? {
        #if os(Linux)
        let path = "/proc/self/exe"
        #else
        guard let launched = CommandLine.arguments.first, launched.contains("/"),
              let resolved = realpath(launched, nil) else { return nil }
        let path = String(cString: resolved)
        free(resolved)
        #endif
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              let digest = try? PortableDigest.sha256Hex(reading: handle) else { return nil }
        return (digest, Int64(status.st_size))
    }

    /// Reads the tool manifest once, compares the SHA-256 and size of its bytes with the plan's pin, and decodes the same
    /// bytes (SWIFT ruling Q-K4-1). The record states the digest, size and source, never the path.
    static func loadManifest(
        path: String,
        source: ExecutorImageManifestSource,
        pin: PlanImageManifestPin,
        record: inout ExecutorRunRecord
    ) throws(RunRefusal) -> ImageToolManifest {
        let field = "imageManifest"
        guard path.hasPrefix("/") else {
            throw RunRefusal(field: field, reason: "The --image-manifest option names a relative path. It must name an absolute file. No tool ran.")
        }
        let bytes: Data
        do throws(ReadError) {
            bytes = try readWhole(path, limit: ImageToolManifest.maximumSize)
        } catch {
            switch (error, source) {
            case (.missing, .image):
                throw RunRefusal(field: field, reason: "The tool manifest is missing at \(ImageToolManifest.imagePath). Outside a Lungfish tool image, pass --image-manifest with the absolute path of the manifest the plan pins. No tool ran.")
            case (.missing, .argument):
                throw RunRefusal(field: field, reason: "The file that --image-manifest names is missing. Name the tool manifest the plan pins. No tool ran.")
            case (.tooLarge(let size), _):
                throw RunRefusal(field: field, reason: "The tool manifest is \(size) bytes, over the limit of \(ImageToolManifest.maximumSize). No tool ran.")
            default:
                throw RunRefusal(field: field, reason: "The tool manifest \(error.phrase) No tool ran.")
            }
        }
        let digest = PortableDigest.sha256Hex(of: bytes)
        record.imageManifest = ExecutorImageManifestRecord(sha256: digest, size: Int64(bytes.count), source: source)
        guard digest == pin.sha256, Int64(bytes.count) == pin.size else {
            throw RunRefusal(
                field: field,
                reason: "The tool manifest has SHA-256 \(digest) and \(bytes.count) bytes, and the plan pins \(pin.sha256) and \(pin.size) bytes. No tool ran."
            )
        }
        do {
            return try ImageToolManifest.decode(bytes)
        } catch let error as ImageToolManifestError {
            throw RunRefusal(field: error.field == field ? field : "\(field).\(error.field)", reason: "\(error.reason) No tool ran.")
        } catch {
            throw RunRefusal(field: field, reason: "The tool manifest cannot be read. No tool ran.")
        }
    }
}

extension RunFiles {
    /// Places each barcode list from the image, then checks every entry but the executor's by size and SHA-256 and
    /// states it in the record's `inputs`. The executor entry was checked as the running binary, and the run never
    /// reads or runs the folder's copy.
    static func checkEntries(
        _ plan: ExecutionPlan, manifest: ImageToolManifest, resolver: PlanResourceResolver, record: inout ExecutorRunRecord
    ) throws(RunRefusal) {
        for (index, entry) in plan.entries.enumerated() where entry.isImageBarcodeList {
            try placeImageFile(entry, field: "entries[\(index)]", manifest: manifest, resolver: resolver)
        }
        for (index, entry) in plan.entries.enumerated() where entry.role != .executor {
            do {
                _ = try resolver.verify(entry)
            } catch {
                // LGE never copies a list the person supplied, so the words say where it goes (BIO-NOTHOST-BARCODE Q2).
                let supplied = entry.isSuppliedBarcodeList
                    ? " LGE does not copy a barcode list you supplied. Put the list \(entry.barcodeList?.name ?? "") with SHA-256 \(entry.sha256) at \(entry.relativePath) before the run."
                    : ""
                throw RunRefusal(field: "entries[\(index)]", reason: "\(error.localizedDescription)\(supplied) No tool ran.")
            }
            record.inputs.append(entry)
        }
    }

    /// Copies the file the tool manifest lists in `files` for `entry`'s role and SHA-256 to the entry's path, under
    /// `barcodes/` only, through a descriptor the resolver opened with no link followed. It neither links to the file
    /// nor reads it in place. The entry check after it reads the copy's size and SHA-256 (executor-plan.md, The barcode
    /// list).
    private static func placeImageFile(
        _ entry: PlanEntry, field: String, manifest: ImageToolManifest, resolver: PlanResourceResolver
    ) throws(RunRefusal) {
        guard let file = manifest.file(role: entry.role, sha256: entry.sha256) else {
            throw RunRefusal(field: field, reason: "The tool image holds no barcode list with SHA-256 \(entry.sha256), which this plan pins. No tool ran.")
        }
        guard entry.relativePath.hasPrefix("barcodes/") else {
            throw RunRefusal(field: field, reason: "The plan places the image's barcode list at \(entry.relativePath), outside barcodes/. No tool ran.")
        }
        let source = open(file.path, O_RDONLY | O_CLOEXEC)
        guard source >= 0 else {
            throw RunRefusal(field: field, reason: "The image's barcode list \(file.path) cannot be read. \(String(cString: strerror(errno))) No tool ran.")
        }
        defer { close(source) }
        let output: PlanOutputFile
        do {
            output = try resolver.openOutput(entry.relativePath)
        } catch {
            throw RunRefusal(field: field, reason: "The executor could not make \(entry.relativePath). \(error.localizedDescription) No tool ran.")
        }
        defer { output.closeDescriptor() }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw RunRefusal(field: field, reason: "The image's barcode list \(file.path) cannot be read. \(String(cString: strerror(errno))) No tool ran.")
            }
            var written = 0
            while written < count {
                let step = buffer.withUnsafeBytes { write(output.fileDescriptor, $0.baseAddress! + written, count - written) }
                if step < 0, errno == EINTR { continue }
                guard step > 0 else {
                    throw RunRefusal(field: field, reason: "The executor could not write \(entry.relativePath). \(String(cString: strerror(errno))) No tool ran.")
                }
                written += step
            }
        }
    }
}

/// What the executor observes of the machine itself under `root` (empty on a run, a folder in a test), never a
/// scheduler's variable or a file one names (SWIFT preflight and identity words).
enum RuntimeObservation {
    /// The identity the run record states: `uname`, the `NSpid` depth, the cgroup version, the observed limits with their
    /// sources, and the subreaper result.
    static func identity(subreaper: ChildSubreaper.Report, root: String = "") -> ExecutorRuntimeIdentity {
        let status = readSmallFile(root + "/proc/self/status")
        let cgroupLines = (readSmallFile(root + "/proc/self/cgroup") ?? "").split(separator: "\n")
        let unified = cgroupLines.first { $0.hasPrefix("0::") }.map { String($0.dropFirst(3)) }
        let cgroupVersion: Int? = unified != nil ? 2 : (cgroupLines.isEmpty ? nil : 1)
        let memTotal = value(of: "MemTotal", in: readSmallFile(root + "/proc/meminfo"))
            .flatMap { $0.split(separator: " ").first }.flatMap { Int64($0) }.map { $0 * 1024 }
        let cgroupFile = unified.map { "/sys/fs/cgroup" + ($0 == "/" ? "" : $0) + "/memory.max" }
        let cgroupMax = cgroupFile.flatMap { readSmallFile(root + $0) }
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let limits = [
            ExecutorObservedLimit(name: "memTotalBytes", value: memTotal.map(String.init), source: "/proc/meminfo MemTotal"),
            ExecutorObservedLimit(
                name: "cpusAllowedList", value: value(of: "Cpus_allowed_list", in: status),
                source: "/proc/self/status Cpus_allowed_list"
            ),
            ExecutorObservedLimit(
                name: "cgroupMemoryMaxBytes", value: cgroupMax.map(String.init),
                source: cgroupFile ?? "/proc/self/cgroup 0:: line"
            ),
        ]
        let depth = value(of: "NSpid", in: status).map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).count }
        let names = kernelNames()
        return ExecutorRuntimeIdentity(
            kernelRelease: names.release, machine: names.machine, pidNamespaceDepth: depth, cgroupVersion: cgroupVersion,
            observedLimits: limits, subreaper: subreaperRecord(subreaper),
            orphanSweep: subreaper.isSet ? .subreaper : .parentWalkOnly
        )
    }

    /// Refuses the plan when its clumpify heap is not below the smallest memory limit observed (tally-r2 K4-16). A value
    /// not observed and the CPU list never refuse.
    static func preflightRefusal(heapGB: Int, limits: [ExecutorObservedLimit]) -> RunRefusal? {
        let heap = Int64(heapGB) * 1_073_741_824
        let memory = limits.filter { $0.name != "cpusAllowedList" }
            .compactMap { limit in limit.value.flatMap { Int64($0) }.map { (limit, $0) } }
        guard let smallest = memory.min(by: { $0.1 < $1.1 }), heap >= smallest.1 else { return nil }
        return RunRefusal(
            field: "storage.clumpifyHeapGB",
            reason: "The plan's clumpify heap of \(heapGB) GB (\(heap) bytes) is not below the memory limit of \(smallest.1) bytes "
                + "that \(smallest.0.source) states. No tool ran."
        )
    }

    static func subreaperRecord(_ report: ChildSubreaper.Report) -> ExecutorStepRecord.Subreaper {
        ExecutorStepRecord.Subreaper(
            state: report.isSet ? "set" : (StepCommand.isLinux ? "notSet" : "unavailable"),
            setterResult: report.setterResult,
            setterResultName: ChildSubreaper.errnoName(report.setterResult),
            getterResult: report.getterResult,
            getterValue: report.getterValue
        )
    }

    /// The text after `name:` on its line, trimmed.
    private static func value(of name: String, in text: String?) -> String? {
        guard let text else { return nil }
        let prefix = name + ":"
        return text.split(separator: "\n").first { $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
    }

    /// Up to 64 KiB of a file, read until its end, since `/proc` files report a size of 0. Nil when it cannot be opened.
    private static func readSmallFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while bytes.count < 1 << 16 {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes += chunk[0..<count]
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func kernelNames() -> (release: String?, machine: String?) {
        var names = utsname()
        guard uname(&names) == 0 else { return (nil, nil) }
        func text<T>(_ field: inout T) -> String {
            withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return (text(&names.release), text(&names.machine))
    }
}
