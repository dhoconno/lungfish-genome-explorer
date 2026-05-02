import Foundation

struct GeneiousDecodedSequenceSet: Sendable, Equatable {
    let documentRelativePath: String
    let documentName: String
    let records: [GeneiousDecodedSequenceRecord]
    let decodedSidecarPaths: Set<String>
    let annotationSidecarPaths: Set<String>
    let hasInlineAnnotations: Bool
    let warnings: [String]
}

struct GeneiousDecodedSequenceRecord: Sendable, Equatable {
    let name: String
    let sequence: String
    let sidecarRelativePath: String
}

struct GeneiousPackedSequenceExtractor {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func extractSequenceSets(rootURL: URL) throws -> [GeneiousDecodedSequenceSet] {
        let candidates = try geneiousXMLCandidates(rootURL: rootURL)
        var decodedSets: [GeneiousDecodedSequenceSet] = []

        for candidate in candidates {
            let parsed = try parseSequenceDocument(candidate.url)
            guard !parsed.records.isEmpty else { continue }

            var records: [GeneiousDecodedSequenceRecord] = []
            var decodedSidecars = Set<String>()
            var warnings = parsed.warnings

            for record in parsed.records {
                guard let fileDataPath = record.charSequenceFileData else { continue }
                guard let length = record.length else {
                    warnings.append("\(candidate.relativePath) sequence \(record.displayName) does not declare a packed sequence length.")
                    continue
                }

                let sidecarURL = resolveFileDataURL(fileDataPath, xmlURL: candidate.url, rootURL: rootURL)
                guard fileManager.fileExists(atPath: sidecarURL.path) else {
                    warnings.append("\(candidate.relativePath) references missing Geneious sequence sidecar \(fileDataPath).")
                    continue
                }

                do {
                    let sequence = try decodePackedNucleotideSequence(from: sidecarURL, expectedLength: length)
                    records.append(GeneiousDecodedSequenceRecord(
                        name: record.displayName,
                        sequence: sequence,
                        sidecarRelativePath: normalizedRelativePath(fileDataPath, xmlRelativePath: candidate.relativePath)
                    ))
                    decodedSidecars.insert(normalizedRelativePath(fileDataPath, xmlRelativePath: candidate.relativePath))
                } catch {
                    warnings.append("\(candidate.relativePath) references unsupported Geneious sequence sidecar \(fileDataPath): \(error.localizedDescription)")
                }
            }

            guard !records.isEmpty else { continue }
            decodedSets.append(GeneiousDecodedSequenceSet(
                documentRelativePath: candidate.relativePath,
                documentName: parsed.documentName ?? URL(fileURLWithPath: candidate.relativePath).deletingPathExtension().lastPathComponent,
                records: records,
                decodedSidecarPaths: decodedSidecars,
                annotationSidecarPaths: Set(parsed.annotationSidecarPaths.map {
                    normalizedRelativePath($0, xmlRelativePath: candidate.relativePath)
                }),
                hasInlineAnnotations: parsed.hasInlineAnnotations,
                warnings: warnings
            ))
        }

        return decodedSets
    }

    private func geneiousXMLCandidates(rootURL: URL) throws -> [GeneiousXMLCandidate] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return isGeneiousXMLCandidate(rootURL) ? [GeneiousXMLCandidate(url: rootURL, relativePath: rootURL.lastPathComponent)] : []
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [GeneiousXMLCandidate] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isHidden == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, isGeneiousXMLCandidate(fileURL) else { continue }
            candidates.append(GeneiousXMLCandidate(
                url: fileURL,
                relativePath: Self.relativePath(from: rootURL, to: fileURL)
            ))
        }

        return candidates.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func isGeneiousXMLCandidate(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "geneious" || ext == "xml" else { return false }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let prefix = String(data: data.prefix(4096), encoding: .utf8) else {
            return false
        }
        return prefix.localizedCaseInsensitiveContains("<geneious")
    }

    private func parseSequenceDocument(_ url: URL) throws -> ParsedGeneiousSequenceDocument {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let parser = XMLParser(data: data)
        let delegate = GeneiousPackedSequenceXMLParser()
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return delegate.document
    }

    private func resolveFileDataURL(_ fileDataPath: String, xmlURL: URL, rootURL: URL) -> URL {
        let rootRelative = rootURL.appendingPathComponent(fileDataPath)
        if fileManager.fileExists(atPath: rootRelative.path) {
            return rootRelative
        }
        return xmlURL.deletingLastPathComponent().appendingPathComponent(fileDataPath)
    }

    private func normalizedRelativePath(_ fileDataPath: String, xmlRelativePath: String) -> String {
        if fileDataPath.contains("/") {
            return fileDataPath
        }
        let xmlParent = URL(fileURLWithPath: xmlRelativePath).deletingLastPathComponent().relativePath
        guard xmlParent != "." else { return fileDataPath }
        return URL(fileURLWithPath: xmlParent).appendingPathComponent(fileDataPath).relativePath
    }

    private func decodePackedNucleotideSequence(from url: URL, expectedLength: Int) throws -> String {
        let stream = try Data(contentsOf: url, options: [.mappedIfSafe])
        let payload = try javaBlockDataPayload(from: stream)
        guard payload.count >= 5 else {
            throw GeneiousPackedSequenceError.unsupportedEncoding
        }
        let encoding = payload[payload.startIndex]

        let lengthStart = payload.index(after: payload.startIndex)
        let packedLength = Int(payload[lengthStart]) << 24
            | Int(payload[payload.index(lengthStart, offsetBy: 1)]) << 16
            | Int(payload[payload.index(lengthStart, offsetBy: 2)]) << 8
            | Int(payload[payload.index(lengthStart, offsetBy: 3)])
        let packedStart = payload.index(payload.startIndex, offsetBy: 5)
        let basesPerByte: Int
        switch encoding {
        case 0x20:
            basesPerByte = 4
        case 0x30:
            basesPerByte = 2
        default:
            throw GeneiousPackedSequenceError.unsupportedEncoding
        }
        guard packedLength >= (expectedLength + basesPerByte - 1) / basesPerByte,
              payload.distance(from: packedStart, to: payload.endIndex) >= packedLength else {
            throw GeneiousPackedSequenceError.truncatedPayload
        }

        var sequence = String()
        sequence.reserveCapacity(expectedLength)
        var emitted = 0
        var index = packedStart
        let packedEnd = payload.index(packedStart, offsetBy: packedLength)
        while index < packedEnd, emitted < expectedLength {
            let byte = payload[index]
            switch encoding {
            case 0x20:
                for shift in stride(from: 6, through: 0, by: -2) {
                    guard emitted < expectedLength else { break }
                    let value = (byte >> UInt8(shift)) & 0x03
                    sequence.append(Self.base(forPackedValue: value))
                    emitted += 1
                }
            case 0x30:
                for shift in [4, 0] {
                    guard emitted < expectedLength else { break }
                    let value = (byte >> UInt8(shift)) & 0x0F
                    sequence.append(Self.base(forPackedValue: value))
                    emitted += 1
                }
            default:
                throw GeneiousPackedSequenceError.unsupportedEncoding
            }
            index = payload.index(after: index)
        }

        guard emitted == expectedLength else {
            throw GeneiousPackedSequenceError.truncatedPayload
        }
        return sequence
    }

    private func javaBlockDataPayload(from stream: Data) throws -> Data {
        guard stream.count >= 4,
              stream[stream.startIndex] == 0xAC,
              stream[stream.index(after: stream.startIndex)] == 0xED else {
            throw GeneiousPackedSequenceError.invalidJavaSerializationStream
        }

        var index = stream.index(stream.startIndex, offsetBy: 4)
        var payload = Data()
        while index < stream.endIndex {
            let tag = stream[index]
            index = stream.index(after: index)
            let chunkLength: Int
            switch tag {
            case 0x77:
                guard index < stream.endIndex else { throw GeneiousPackedSequenceError.truncatedPayload }
                chunkLength = Int(stream[index])
                index = stream.index(after: index)
            case 0x7A:
                guard stream.distance(from: index, to: stream.endIndex) >= 4 else {
                    throw GeneiousPackedSequenceError.truncatedPayload
                }
                chunkLength = Int(stream[index]) << 24
                    | Int(stream[stream.index(index, offsetBy: 1)]) << 16
                    | Int(stream[stream.index(index, offsetBy: 2)]) << 8
                    | Int(stream[stream.index(index, offsetBy: 3)])
                index = stream.index(index, offsetBy: 4)
            default:
                throw GeneiousPackedSequenceError.unexpectedJavaSerializationTag(tag)
            }

            guard chunkLength >= 0, stream.distance(from: index, to: stream.endIndex) >= chunkLength else {
                throw GeneiousPackedSequenceError.truncatedPayload
            }
            payload.append(stream[index..<stream.index(index, offsetBy: chunkLength)])
            index = stream.index(index, offsetBy: chunkLength)
        }

        return payload
    }

    private static func base(forPackedValue value: UInt8) -> Character {
        switch value {
        case 0: return "A"
        case 1: return "C"
        case 2: return "G"
        case 3: return "T"
        case 4...15: return "N"
        default: return "N"
        }
    }

    private static func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }
}

private struct GeneiousXMLCandidate: Equatable {
    let url: URL
    let relativePath: String
}

private struct ParsedGeneiousSequenceDocument: Equatable {
    var documentName: String?
    var records: [ParsedGeneiousSequenceRecord] = []
    var annotationSidecarPaths: [String] = []
    var hasInlineAnnotations = false
    var warnings: [String] = []
}

private struct ParsedGeneiousSequenceRecord: Equatable {
    var name: String?
    var cacheName: String?
    var charSequenceFileData: String?
    var length: Int?

    var displayName: String {
        let candidate = name ?? cacheName ?? charSequenceFileData ?? "Geneious Sequence"
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Geneious Sequence" : candidate
    }
}

private enum GeneiousPackedSequenceError: Error, LocalizedError, Equatable {
    case invalidJavaSerializationStream
    case unexpectedJavaSerializationTag(UInt8)
    case unsupportedEncoding
    case truncatedPayload

    var errorDescription: String? {
        switch self {
        case .invalidJavaSerializationStream:
            return "invalid Java serialization stream"
        case .unexpectedJavaSerializationTag(let tag):
            return "unexpected Java serialization tag 0x\(String(tag, radix: 16))"
        case .unsupportedEncoding:
            return "unsupported packed nucleotide encoding"
        case .truncatedPayload:
            return "truncated packed nucleotide payload"
        }
    }
}

private final class GeneiousPackedSequenceXMLParser: NSObject, XMLParserDelegate {
    private(set) var document = ParsedGeneiousSequenceDocument()
    private var elementStack: [String] = []
    private var inSequenceListDocument = false
    private var currentRecord: ParsedGeneiousSequenceRecord?
    private var activeCapture: CaptureTarget?
    private var activeText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)

        if elementName == "geneiousDocument" {
            inSequenceListDocument = (attributeDict["class"] ?? "").contains("DefaultSequenceListDocument")
        }

        guard inSequenceListDocument else { return }

        if elementName == "nucleotideSequence" {
            currentRecord = ParsedGeneiousSequenceRecord()
            return
        }

        if currentRecord != nil, elementName == "charSequence" {
            currentRecord?.charSequenceFileData = attributeDict["xmlFileData"]
            currentRecord?.length = attributeDict["length"].flatMap(Int.init)
            return
        }

        if currentRecord != nil, elementName == "sequenceAnnotations" {
            if let fileData = attributeDict["xmlFileData"] {
                appendUnique(fileData, to: &document.annotationSidecarPaths)
            } else {
                document.hasInlineAnnotations = true
            }
            return
        }

        if elementName == "hiddenField" {
            switch attributeDict["name"] {
            case "cache_name", "override_cache_name":
                beginCapture(.documentName)
            default:
                break
            }
            return
        }

        if currentRecord != nil {
            if elementName == "name", directParentIs("nucleotideSequence") {
                beginCapture(.sequenceName)
            } else if elementName == "cache_name" {
                beginCapture(.sequenceCacheName)
            }
            return
        }

        if elementName == "cache_name" || elementName == "override_cache_name" {
            beginCapture(.documentName)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeCapture != nil else { return }
        activeText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if let activeCapture {
            finishCapture(activeCapture)
        }

        if elementName == "nucleotideSequence", let currentRecord {
            if currentRecord.charSequenceFileData != nil {
                document.records.append(currentRecord)
            }
            self.currentRecord = nil
        }

        if elementName == "geneiousDocument" {
            inSequenceListDocument = false
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    private func beginCapture(_ target: CaptureTarget) {
        activeCapture = target
        activeText = ""
    }

    private func finishCapture(_ target: CaptureTarget) {
        let value = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            activeCapture = nil
            activeText = ""
        }
        guard !value.isEmpty else { return }

        switch target {
        case .documentName:
            if document.documentName == nil {
                document.documentName = value
            }
        case .sequenceName:
            currentRecord?.name = value
        case .sequenceCacheName:
            currentRecord?.cacheName = value
        }
    }

    private func directParentIs(_ parent: String) -> Bool {
        guard elementStack.count >= 2 else { return false }
        return elementStack[elementStack.count - 2] == parent
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private enum CaptureTarget {
        case documentName
        case sequenceName
        case sequenceCacheName
    }
}
