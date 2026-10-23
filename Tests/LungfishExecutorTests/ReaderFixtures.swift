import Foundation
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The pigz the decompression tests run: `LUNGFISH_PIGZ` (the tier unpacks one), else the managed one on this Mac. A test
/// skips without one, and fails instead under `LUNGFISH_REQUIRE_TOOLS=1`, as `ToolAvailability` does (QA 3). The executor's
/// test target sees only the executor and the portable layer, so it carries this small copy of that rule.
enum ReaderTools {
    static func pigz() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["LUNGFISH_PIGZ"], NSHomeDirectory() + "/.lungfish/conda/envs/pigz/bin/pigz"]
        if let found = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let message = "pigz is not installed. Set LUNGFISH_PIGZ or install the managed pigz"
        if environment["LUNGFISH_REQUIRE_TOOLS"] == "1" {
            throw ExecutorTestSupport.Failure(description: message + ", since LUNGFISH_REQUIRE_TOOLS=1")
        }
        throw XCTSkip(message)
    }
}

/// The decompression fixtures, made fresh in a scratch folder.
///
/// The tier's Swift container has `gzip` but no `bgzip`, so the BGZF fixture is written in bgzip's layout: each block holds
/// at most 65,280 input bytes as one gzip member (compressed here by `/usr/bin/gzip -n`), whose header gains the extra
/// subfield `BC` with the block's size less one, and the file ends with bgzip's 28-byte EOF block (SAM specification 4.1).
struct ReaderFixtures {
    static let recordCount = 3_000
    static let bgzfEOF: [UInt8] = [
        0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0, 0xFF, 0x06, 0, 0x42, 0x43, 0x02, 0, 0x1B, 0, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]

    let folder: String

    func file(_ name: String) -> URL { URL(fileURLWithPath: "\(folder)/\(name)") }
    var plain: URL { file("plain.fastq") }
    var bgzf: URL { file("bgzf.fastq.gz") }
    var single: URL { file("single.fastq.gz") }
    var pigzMade: URL { file("pigz.fastq.gz") }
    var cutShort: URL { file("cut.fastq.gz") }
    var badCRC: URL { file("badcrc.fastq.gz") }

    /// Writes the plain file and the gzip fixtures. `pigz` also writes the pigz-made one.
    static func make(pigz: String?) throws -> ReaderFixtures {
        let fixtures = ReaderFixtures(folder: try ExecutorTestSupport.scratchFolder())
        let plain = plainRecords()
        try plain.write(to: fixtures.plain)
        var bgzf = Data()
        var offset = 0
        var index = 0
        while offset < plain.count {
            let end = min(offset + 65_280, plain.count)
            let piece = "\(fixtures.folder)/block-\(index)"
            try plain.subdata(in: offset..<end).write(to: URL(fileURLWithPath: piece))
            bgzf.append(try bgzfBlock(from: run("/usr/bin/gzip", ["-c", "-n", piece], in: fixtures.folder, name: "block-\(index)")))
            offset = end
            index += 1
        }
        bgzf.append(contentsOf: bgzfEOF)
        try bgzf.write(to: fixtures.bgzf)
        try run("/usr/bin/gzip", ["-c", "-n", fixtures.plain.path], in: fixtures.folder, name: "single").write(to: fixtures.single)
        if let pigz {
            try run(pigz, ["-c", "-n", fixtures.plain.path], in: fixtures.folder, name: "pigz").write(to: fixtures.pigzMade)
        }
        try bgzf.prefix(bgzf.count - 100).write(to: fixtures.cutShort)
        // The first byte of block 2's CRC-32, which sits 8 bytes before the block's end.
        let starts = blockStarts(bgzf)
        var damaged = [UInt8](bgzf)
        damaged[starts[2] - 8] ^= 0xFF
        try Data(damaged).write(to: fixtures.badCRC)
        return fixtures
    }

    /// Runs `program` with stdout in a file of `folder` and returns what it wrote.
    static func run(_ program: String, _ arguments: [String], in folder: String, name: String) throws -> Data {
        let pid = try ExecutorTestSupport.spawn(program, arguments, folder: folder, name: name)
        guard let exit = ExecutorTestSupport.waitForExit(pid, timeout: 60), exit.termination == .exited(code: 0) else {
            throw ExecutorTestSupport.Failure(description: "\(program) \(arguments) failed")
        }
        return try Data(contentsOf: URL(fileURLWithPath: "\(folder)/\(name).out"))
    }

    /// A `gzip -n` member rewritten as a BGZF block.
    static func bgzfBlock(from member: Data) throws -> Data {
        let bytes = [UInt8](member)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8, bytes[3] == 0 else {
            throw ExecutorTestSupport.Failure(description: "gzip -n wrote a header with flags set")
        }
        let size = 18 + bytes.count - 10
        guard size <= 65_536 else { throw ExecutorTestSupport.Failure(description: "a block of \(size) bytes is too big for BGZF") }
        let bsize = size - 1
        let header: [UInt8] = [
            0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, bytes[8], bytes[9], 6, 0, 0x42, 0x43, 2, 0, UInt8(bsize & 0xFF), UInt8(bsize >> 8),
        ]
        return Data(header + bytes[10...])
    }

    /// Where each BGZF block starts, read from the BSIZE fields, with the file's length last when every block parsed.
    static func blockStarts(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var offset = 0
        while offset + 18 <= bytes.count, bytes[offset] == 0x1F, bytes[offset + 1] == 0x8B, bytes[offset + 3] & 4 != 0,
              bytes[offset + 12] == 0x42, bytes[offset + 13] == 0x43 {
            starts.append(offset)
            offset += (Int(bytes[offset + 16]) | Int(bytes[offset + 17]) << 8) + 1
        }
        if offset == bytes.count {
            starts.append(offset)
        }
        return starts
    }

    /// Records of 90 to 150 bases with qualities from Q0 to Q40, the same on every run.
    static func plainRecords() -> Data {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        let bases = Array("ACGT".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(recordCount * 280)
        for index in 0..<recordCount {
            let length = 90 + next() % 61
            bytes += Array("@read\(index) lane=K3B\n".utf8)
            for _ in 0..<length { bytes.append(bases[next() % 4]) }
            bytes += Array("\n+\n".utf8)
            for _ in 0..<length { bytes.append(UInt8(33 + next() % 41)) }
            bytes.append(0x0A)
        }
        return Data(bytes)
    }
}
