import Foundation
import LungfishIO

struct TwelveSFastqRecord: Equatable, Sendable {
    let identifier: String
    let sequence: String
}

enum TwelveSFastqReaderError: Error, LocalizedError, Equatable {
    case malformedRecord(URL, Int)
    case truncatedRecord(URL)

    var errorDescription: String? {
        switch self {
        case let .malformedRecord(url, lineNumber):
            return "Malformed FASTQ record in \(url.path) near line \(lineNumber)."
        case let .truncatedRecord(url):
            return "FASTQ file ended with a truncated record: \(url.path)."
        }
    }
}

struct TwelveSFastqReader: Sendable {
    let url: URL

    func records() -> AsyncThrowingStream<TwelveSFastqRecord, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer: [String] = []
                    var lineNumber = 0
                    for try await line in url.linesAutoDecompressing() {
                        lineNumber += 1
                        buffer.append(line)
                        if buffer.count == 4 {
                            guard buffer[0].hasPrefix("@"), buffer[2].hasPrefix("+") else {
                                throw TwelveSFastqReaderError.malformedRecord(url, lineNumber - 3)
                            }
                            let identifier = String(buffer[0].dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                            let sequence = buffer[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            if case .terminated = continuation.yield(
                                TwelveSFastqRecord(identifier: identifier, sequence: sequence)
                            ) {
                                throw CancellationError()
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        throw TwelveSFastqReaderError.truncatedRecord(url)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
