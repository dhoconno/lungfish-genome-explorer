import Testing
import Foundation
@testable import LungfishCore

@Suite("SRADownloadFallback")
struct SRADownloadFallbackTests {
    @Test("falls back to SRA Toolkit when ENA path raises")
    func fallsBackToToolkit() async throws {
        let enaCalls = Counter()
        let toolkitCalls = Counter()
        let service = SRAService(
            enaDownloader: { _, _ in
                enaCalls.increment()
                throw NSError(domain: "ena", code: 404)
            },
            toolkitDownloader: { _, _ in
                toolkitCalls.increment()
                return [URL(fileURLWithPath: "/tmp/SRR123_1.fastq")]
            }
        )
        let urls = try await service.downloadFASTQWithFallback(accession: "SRR123", outputDir: nil)
        #expect(enaCalls.value == 1)
        #expect(toolkitCalls.value == 1)
        #expect(urls.count == 1)
    }

    @Test("surfaces both errors when both paths fail")
    func surfacesBothErrors() async throws {
        let service = SRAService(
            enaDownloader: { _, _ in throw NSError(domain: "ena", code: 404) },
            toolkitDownloader: { _, _ in throw NSError(domain: "toolkit", code: 1) }
        )
        await #expect(throws: SRAError.self) {
            try await service.downloadFASTQWithFallback(accession: "SRR123", outputDir: nil)
        }
    }

    @Test("invokes onFallback exactly once when ENA fails")
    func invokesOnFallbackWhenENAFails() async throws {
        let messages = MessageCollector()
        let service = SRAService(
            enaDownloader: { _, _ in throw NSError(domain: "ena", code: 404) },
            toolkitDownloader: { _, _ in
                [URL(fileURLWithPath: "/tmp/SRR123_1.fastq")]
            }
        )
        _ = try await service.downloadFASTQWithFallback(
            accession: "SRR123",
            outputDir: nil,
            progress: nil,
            onFallback: { message in
                messages.append(message)
            }
        )
        #expect(messages.count == 1)
        let captured = messages.value.first ?? ""
        #expect(captured.contains("SRA Toolkit"))
        #expect(captured.contains("prefetch"))
        #expect(captured.contains("fasterq-dump"))
    }

    @Test("does not invoke onFallback when ENA succeeds")
    func doesNotInvokeOnFallbackWhenENASucceeds() async throws {
        let messages = MessageCollector()
        let service = SRAService(
            enaDownloader: { _, _ in
                [URL(fileURLWithPath: "/tmp/SRR123_1.fastq")]
            },
            toolkitDownloader: { _, _ in
                [URL(fileURLWithPath: "/tmp/should-not-be-called.fastq")]
            }
        )
        _ = try await service.downloadFASTQWithFallback(
            accession: "SRR123",
            outputDir: nil,
            progress: nil,
            onFallback: { message in
                messages.append(message)
            }
        )
        #expect(messages.count == 0)
    }
}

/// Thread-safe call counter used by the injected download closures.
///
/// `var` captures inside `@Sendable` closures don't compile under Swift 6
/// strict concurrency, so the plan's `var enaCalls = 0` is replaced with this
/// reference-typed lock-guarded counter.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}

/// Thread-safe collector for `onFallback` messages captured by injected closures.
private final class MessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _messages.count
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        _messages.append(message)
    }
}
