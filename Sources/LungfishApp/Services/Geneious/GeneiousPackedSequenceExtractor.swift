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
    let annotations: [GeneiousDecodedAnnotation]
}

struct GeneiousDecodedAnnotation: Sendable, Equatable {
    let type: String
    let description: String
    let intervals: [GeneiousDecodedAnnotationInterval]
    let qualifiers: [GeneiousDecodedAnnotationQualifier]
}

struct GeneiousDecodedAnnotationInterval: Sendable, Equatable {
    let minimumIndex: Int
    let maximumIndex: Int
    let direction: String
}

struct GeneiousDecodedAnnotationQualifier: Sendable, Equatable {
    let name: String
    let value: String
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
                    let annotations = try decodeAnnotations(
                        for: record,
                        xmlURL: candidate.url,
                        rootURL: rootURL,
                        xmlRelativePath: candidate.relativePath,
                        warnings: &warnings
                    )
                    records.append(GeneiousDecodedSequenceRecord(
                        name: record.displayName,
                        sequence: sequence,
                        sidecarRelativePath: normalizedRelativePath(fileDataPath, xmlRelativePath: candidate.relativePath),
                        annotations: annotations
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

    private func decodeAnnotations(
        for record: ParsedGeneiousSequenceRecord,
        xmlURL: URL,
        rootURL: URL,
        xmlRelativePath: String,
        warnings: inout [String]
    ) throws -> [GeneiousDecodedAnnotation] {
        var annotations = record.inlineAnnotations
        guard let fileDataPath = record.annotationFileData else {
            return annotations
        }

        let sidecarURL = resolveFileDataURL(fileDataPath, xmlURL: xmlURL, rootURL: rootURL)
        guard fileManager.fileExists(atPath: sidecarURL.path) else {
            warnings.append("\(xmlRelativePath) references missing Geneious annotation sidecar \(fileDataPath).")
            return annotations
        }

        do {
            let sidecarAnnotations = try decodeAnnotationSidecar(from: sidecarURL)
            annotations.append(contentsOf: sidecarAnnotations)
        } catch {
            let relative = normalizedRelativePath(fileDataPath, xmlRelativePath: xmlRelativePath)
            warnings.append("\(relative) contains Geneious annotations that could not be decoded: \(error.localizedDescription)")
        }
        return annotations
    }

    private func decodeAnnotationSidecar(from url: URL) throws -> [GeneiousDecodedAnnotation] {
        let stream = try Data(contentsOf: url, options: [.mappedIfSafe])
        let payload = try javaBlockDataPayload(from: stream)
        return try GeneiousAnnotationSidecarParser(payload: [UInt8](payload)).parse()
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
    var annotationFileData: String?
    var length: Int?
    var inlineAnnotations: [GeneiousDecodedAnnotation] = []

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

private enum GeneiousAnnotationSidecarError: Error, LocalizedError, Equatable {
    case truncatedPayload
    case noAnnotationsDecoded

    var errorDescription: String? {
        switch self {
        case .truncatedPayload:
            return "truncated Geneious annotation payload"
        case .noAnnotationsDecoded:
            return "unsupported Geneious annotation payload"
        }
    }
}

private struct GeneiousAnnotationSidecarParser {
    private let payload: [UInt8]

    init(payload: [UInt8]) {
        self.payload = payload
    }

    func parse() throws -> [GeneiousDecodedAnnotation] {
        guard payload.count >= 13 else { throw GeneiousAnnotationSidecarError.truncatedPayload }
        let declaredCount = readUInt32(at: 9)
        var index = 13
        var lastType = "region"
        var annotations: [GeneiousDecodedAnnotation] = []

        while annotations.count < declaredCount && index < payload.count {
            let parsed = parseRecord(at: index, lastType: lastType)
                ?? findNextRecord(from: index + 1, lastType: lastType)
            guard let parsed else { break }

            annotations.append(parsed.annotation)
            lastType = parsed.annotation.type
            index = parsed.nextIndex
        }

        if annotations.isEmpty && declaredCount > 0 {
            throw GeneiousAnnotationSidecarError.noAnnotationsDecoded
        }
        return annotations
    }

    private func findNextRecord(from start: Int, lastType: String) -> ParsedSidecarRecord? {
        let limit = min(payload.count, start + 20_000)
        guard start < limit else { return nil }
        for candidate in start..<limit {
            if let parsed = parseRecord(at: candidate, lastType: lastType) {
                return parsed
            }
        }
        return nil
    }

    private func parseRecord(at index: Int, lastType: String) -> ParsedSidecarRecord? {
        var attempts: [RecordAttempt] = []

        if let type = readSidecarString(at: index),
           let description = readSidecarString(at: type.nextIndex) {
            attempts.append(RecordAttempt(
                type: type.value,
                description: description.value,
                locationIndex: description.nextIndex
            ))
        }

        for prefixLength in 1...10 {
            if let description = readSidecarString(at: index + prefixLength) {
                attempts.append(RecordAttempt(
                    type: lastType,
                    description: description.value,
                    locationIndex: description.nextIndex
                ))
            }
        }

        for attempt in attempts {
            guard let location = readLocation(at: attempt.locationIndex),
                  location.nextIndex + 4 <= payload.count else {
                continue
            }
            let qualifierCount = readUInt32(at: location.nextIndex)
            guard qualifierCount <= 64 else { continue }
            var qualifierIndex = location.nextIndex + 4
            var qualifiers: [GeneiousDecodedAnnotationQualifier] = []
            var qualifiersAreValid = true

            for _ in 0..<qualifierCount {
                guard let name = readEncodedValue(at: qualifierIndex) else {
                    qualifiersAreValid = false
                    break
                }
                qualifierIndex = name.nextIndex
                guard let value = readEncodedValue(at: qualifierIndex) else {
                    qualifiersAreValid = false
                    break
                }
                qualifierIndex = value.nextIndex
                if let qualifierName = name.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !qualifierName.isEmpty,
                   let qualifierValue = value.value {
                    qualifiers.append(GeneiousDecodedAnnotationQualifier(
                        name: qualifierName,
                        value: qualifierValue
                    ))
                }
            }

            guard qualifiersAreValid else { continue }
            let type = attempt.type.trimmingCharacters(in: .whitespacesAndNewlines)
            let annotation = GeneiousDecodedAnnotation(
                type: type.isEmpty ? "region" : type,
                description: attempt.description,
                intervals: location.intervals,
                qualifiers: qualifiers
            )
            return ParsedSidecarRecord(annotation: annotation, nextIndex: qualifierIndex)
        }

        return nil
    }

    private func readLocation(at index: Int) -> ParsedSidecarLocation? {
        if index + 5 <= payload.count {
            let count = readUInt32(at: index)
            if count > 0,
               count <= 256,
               index + 4 + (count * 9) <= payload.count,
               isPlausibleDirectionFlag(payload[index + 4]) {
                let location = readLocationIntervals(count: count, at: index + 4)
                if let location {
                    return location
                }
            }

            if payload[index] == 0x05 {
                let typedCount = readUInt32(at: index + 1)
                if typedCount > 0,
                   typedCount <= 256,
                   index + 5 + (typedCount * 9) <= payload.count,
                   isPlausibleDirectionFlag(payload[index + 5]) {
                    let location = readLocationIntervals(count: typedCount, at: index + 5)
                    if let location {
                        return location
                    }
                }
            }
        }

        guard index + 9 <= payload.count, isPlausibleDirectionFlag(payload[index]) else {
            return nil
        }
        let minimumIndex = readUInt32(at: index + 1)
        let maximumIndex = readUInt32(at: index + 5)
        guard minimumIndex <= maximumIndex, maximumIndex < 1_000_000_000 else {
            return nil
        }
        return ParsedSidecarLocation(
            intervals: [
                makeSidecarInterval(
                    flag: payload[index],
                    minimumIndex: minimumIndex,
                    maximumIndex: maximumIndex
                ),
            ],
            nextIndex: index + 9
        )
    }

    private func readLocationIntervals(count: Int, at startIndex: Int) -> ParsedSidecarLocation? {
        var index = startIndex
        var intervals: [GeneiousDecodedAnnotationInterval] = []
        intervals.reserveCapacity(count)
        for _ in 0..<count {
            guard index + 9 <= payload.count, isPlausibleDirectionFlag(payload[index]) else {
                return nil
            }
            let minimumIndex = readUInt32(at: index + 1)
            let maximumIndex = readUInt32(at: index + 5)
            guard minimumIndex <= maximumIndex, maximumIndex < 1_000_000_000 else {
                return nil
            }
            intervals.append(makeSidecarInterval(
                flag: payload[index],
                minimumIndex: minimumIndex,
                maximumIndex: maximumIndex
            ))
            index += 9
        }
        return ParsedSidecarLocation(intervals: intervals, nextIndex: index)
    }

    private func makeSidecarInterval(
        flag: UInt8,
        minimumIndex: Int,
        maximumIndex: Int
    ) -> GeneiousDecodedAnnotationInterval {
        GeneiousDecodedAnnotationInterval(
            minimumIndex: max(0, minimumIndex - 1),
            maximumIndex: max(0, maximumIndex - 1),
            direction: sidecarDirection(flag)
        )
    }

    private func readEncodedValue(at index: Int) -> EncodedSidecarValue? {
        if let string = readSidecarString(at: index) {
            return EncodedSidecarValue(value: string.value, nextIndex: string.nextIndex)
        }
        guard index < payload.count else { return nil }
        var nextIndex = index + 1
        if nextIndex < payload.count && (payload[index] >= 0x80 || payload[nextIndex] >= 0x80) {
            nextIndex += 1
        }
        return EncodedSidecarValue(value: nil, nextIndex: nextIndex)
    }

    private func readSidecarString(at index: Int) -> SidecarString? {
        guard index + 3 <= payload.count, payload[index] == 0 else { return nil }
        let length = readUInt24(at: index)
        guard length > 0, length <= 512, index + 3 + length <= payload.count else {
            return nil
        }
        let bytes = payload[(index + 3)..<(index + 3 + length)]
        let printable = bytes.filter { byte in
            byte >= 32 || byte == 9 || byte == 10 || byte == 13
        }.count
        guard printable >= max(1, (bytes.count * 4) / 5),
              let value = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        return SidecarString(value: value, nextIndex: index + 3 + length)
    }

    private func readUInt24(at index: Int) -> Int {
        Int(payload[index]) << 16
            | Int(payload[index + 1]) << 8
            | Int(payload[index + 2])
    }

    private func readUInt32(at index: Int) -> Int {
        Int(payload[index]) << 24
            | Int(payload[index + 1]) << 16
            | Int(payload[index + 2]) << 8
            | Int(payload[index + 3])
    }

    private func isPlausibleDirectionFlag(_ flag: UInt8) -> Bool {
        switch flag {
        case 0x00, 0x40, 0x4E, 0x50, 0x60, 0x80, 0xC0:
            return true
        default:
            return false
        }
    }

    private func sidecarDirection(_ flag: UInt8) -> String {
        if flag & 0x80 != 0 {
            return "rightToLeft"
        }
        if flag & 0x40 != 0 {
            return "leftToRight"
        }
        return "none"
    }
}

private struct ParsedSidecarRecord {
    let annotation: GeneiousDecodedAnnotation
    let nextIndex: Int
}

private struct RecordAttempt {
    let type: String
    let description: String
    let locationIndex: Int
}

private struct ParsedSidecarLocation {
    let intervals: [GeneiousDecodedAnnotationInterval]
    let nextIndex: Int
}

private struct SidecarString {
    let value: String
    let nextIndex: Int
}

private struct EncodedSidecarValue {
    let value: String?
    let nextIndex: Int
}

private final class GeneiousPackedSequenceXMLParser: NSObject, XMLParserDelegate {
    private(set) var document = ParsedGeneiousSequenceDocument()
    private var elementStack: [String] = []
    private var inSequenceListDocument = false
    private var currentRecord: ParsedGeneiousSequenceRecord?
    private var currentAnnotation: ParsedAnnotationBuilder?
    private var currentInterval: ParsedAnnotationIntervalBuilder?
    private var currentQualifier: ParsedAnnotationQualifierBuilder?
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
                currentRecord?.annotationFileData = fileData
                appendUnique(fileData, to: &document.annotationSidecarPaths)
            } else {
                currentRecord?.inlineAnnotations = []
                document.hasInlineAnnotations = true
            }
            return
        }

        if currentRecord != nil, elementName == "annotation" {
            currentAnnotation = ParsedAnnotationBuilder()
            return
        }

        if currentAnnotation != nil, elementName == "interval" {
            currentInterval = ParsedAnnotationIntervalBuilder()
            return
        }

        if currentAnnotation != nil, elementName == "qualifier" {
            currentQualifier = ParsedAnnotationQualifierBuilder()
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
            } else if currentAnnotation != nil, elementName == "description", directParentIs("annotation") {
                beginCapture(.annotationDescription)
            } else if currentAnnotation != nil, elementName == "type", directParentIs("annotation") {
                beginCapture(.annotationType)
            } else if currentInterval != nil, elementName == "minimumIndex", directParentIs("interval") {
                beginCapture(.intervalMinimumIndex)
            } else if currentInterval != nil, elementName == "maximumIndex", directParentIs("interval") {
                beginCapture(.intervalMaximumIndex)
            } else if currentInterval != nil, elementName == "direction", directParentIs("interval") {
                beginCapture(.intervalDirection)
            } else if currentQualifier != nil, elementName == "name", directParentIs("qualifier") {
                beginCapture(.qualifierName)
            } else if currentQualifier != nil, elementName == "value", directParentIs("qualifier") {
                beginCapture(.qualifierValue)
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

        if elementName == "interval", let currentInterval {
            if let interval = currentInterval.makeInterval() {
                currentAnnotation?.intervals.append(interval)
            }
            self.currentInterval = nil
        }

        if elementName == "qualifier", let currentQualifier {
            if let qualifier = currentQualifier.makeQualifier() {
                currentAnnotation?.qualifiers.append(qualifier)
            }
            self.currentQualifier = nil
        }

        if elementName == "annotation", let currentAnnotation {
            if let annotation = currentAnnotation.makeAnnotation() {
                currentRecord?.inlineAnnotations.append(annotation)
            }
            self.currentAnnotation = nil
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
        case .annotationDescription:
            currentAnnotation?.description = value
        case .annotationType:
            currentAnnotation?.type = value
        case .intervalMinimumIndex:
            currentInterval?.minimumIndex = Int(value)
        case .intervalMaximumIndex:
            currentInterval?.maximumIndex = Int(value)
        case .intervalDirection:
            currentInterval?.direction = value
        case .qualifierName:
            currentQualifier?.name = value
        case .qualifierValue:
            currentQualifier?.value = value
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
        case annotationDescription
        case annotationType
        case intervalMinimumIndex
        case intervalMaximumIndex
        case intervalDirection
        case qualifierName
        case qualifierValue
    }
}

private struct ParsedAnnotationBuilder {
    var type = "region"
    var description = ""
    var intervals: [GeneiousDecodedAnnotationInterval] = []
    var qualifiers: [GeneiousDecodedAnnotationQualifier] = []

    func makeAnnotation() -> GeneiousDecodedAnnotation? {
        guard !intervals.isEmpty else { return nil }
        return GeneiousDecodedAnnotation(
            type: type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "region" : type,
            description: description,
            intervals: intervals,
            qualifiers: qualifiers
        )
    }
}

private struct ParsedAnnotationIntervalBuilder {
    var minimumIndex: Int?
    var maximumIndex: Int?
    var direction = "none"

    func makeInterval() -> GeneiousDecodedAnnotationInterval? {
        guard let minimumIndex, let maximumIndex else { return nil }
        return GeneiousDecodedAnnotationInterval(
            minimumIndex: minimumIndex,
            maximumIndex: maximumIndex,
            direction: direction
        )
    }
}

private struct ParsedAnnotationQualifierBuilder {
    var name = ""
    var value = ""

    func makeQualifier() -> GeneiousDecodedAnnotationQualifier? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        return GeneiousDecodedAnnotationQualifier(name: trimmedName, value: value)
    }
}
