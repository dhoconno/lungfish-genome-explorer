import Foundation

enum Primer3BoulderWriter {
    static func makeInput(templates: [Primer3PreparedTemplate], options: Primer3DesignOptions) throws -> String {
        try Primer3DesignPipeline.validate(options)
        return try templates.map { template in
            let maskedTemplate = try maskedSequence(for: template)
            var lines = [
                "SEQUENCE_ID=\(template.resultID.uuidString)",
                "SEQUENCE_TEMPLATE=\(maskedTemplate)",
            ]
            if let start = options.targetStart, let end = options.targetEnd {
                guard end <= template.sequence.count else { throw Primer3DesignError.invalidRequest("target exceeds template \(template.title)") }
                lines.append("SEQUENCE_TARGET=\(start - 1),\(end - start + 1)")
            }
            lines += [
                "PRIMER_TASK=generic",
                "PRIMER_FIRST_BASE_INDEX=0",
                "PRIMER_PICK_LEFT_PRIMER=1", "PRIMER_PICK_RIGHT_PRIMER=1",
                "PRIMER_PICK_INTERNAL_OLIGO=\(options.pickInternalOligo ? 1 : 0)",
                "PRIMER_PRODUCT_SIZE_RANGE=\(options.productSizeMin)-\(options.productSizeMax)",
                "PRIMER_NUM_RETURN=\(options.pairCount)",
                "PRIMER_MIN_SIZE=\(options.primerMinSize)", "PRIMER_OPT_SIZE=\(options.primerOptSize)", "PRIMER_MAX_SIZE=\(options.primerMaxSize)",
                "PRIMER_MIN_TM=\(options.primerMinTm)", "PRIMER_OPT_TM=\(options.primerOptTm)", "PRIMER_MAX_TM=\(options.primerMaxTm)",
                "PRIMER_MIN_GC=\(options.primerMinGC)", "PRIMER_MAX_GC=\(options.primerMaxGC)",
                "PRIMER_MAX_NS_ACCEPTED=0", "PRIMER_INTERNAL_MAX_NS_ACCEPTED=0",
                "PRIMER_EXPLAIN_FLAG=1", "="
            ]
            return lines.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }

    static func maskedSequence(for template: Primer3PreparedTemplate) throws -> String {
        var bases = Array(template.sequence)
        for range in template.excludedRegions {
            guard range.lowerBound >= 0, range.upperBound <= bases.count else {
                throw Primer3DesignError.invalidRequest("excluded binding region exceeds template \(template.title)")
            }
            for index in range { bases[index] = "N" }
        }
        return String(bases)
    }
}

enum Primer3BoulderParser {
    static func parse(_ text: String, expectedResultIDs: [UUID]) throws -> [Primer3TemplateResult] {
        var records: [String] = [], current: [Substring] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line == "=" { records.append(current.joined(separator: "\n")); current = [] }
            else if !line.isEmpty { current.append(line) }
        }
        guard current.isEmpty else { throw Primer3DesignError.malformedOutput("unterminated Boulder record") }
        guard records.count == expectedResultIDs.count else { throw Primer3DesignError.malformedOutput("expected \(expectedResultIDs.count) records, found \(records.count)") }
        return try zip(records, expectedResultIDs).map { record, expectedID in
            var fields: [String: String] = [:]
            for line in record.split(whereSeparator: \.isNewline) {
                guard let equal = line.firstIndex(of: "=") else { throw Primer3DesignError.malformedOutput("line lacks '='") }
                let key = String(line[..<equal])
                guard fields[key] == nil else { throw Primer3DesignError.malformedOutput("duplicate \(key)") }
                fields[key] = String(line[line.index(after: equal)...])
            }
            guard fields["SEQUENCE_ID"] == expectedID.uuidString else { throw Primer3DesignError.malformedOutput("unexpected or missing SEQUENCE_ID") }
            let count: Int
            if let rawCount = fields["PRIMER_PAIR_NUM_RETURNED"] { count = try integer(rawCount, "PRIMER_PAIR_NUM_RETURNED") }
            else if fields["PRIMER_ERROR"] != nil { count = 0 }
            else { throw Primer3DesignError.malformedOutput("missing PRIMER_PAIR_NUM_RETURNED") }
            var pairs: [Primer3Pair] = []
            for index in 0..<count {
                let left = try oligo(fields, prefix: "PRIMER_LEFT_\(index)", orientation: .forward)
                let right = try oligo(fields, prefix: "PRIMER_RIGHT_\(index)", orientation: .reverse)
                let internalOligo: Primer3Oligo?
                if fields["PRIMER_INTERNAL_\(index)"] != nil { internalOligo = try oligo(fields, prefix: "PRIMER_INTERNAL_\(index)", orientation: .forward) }
                else { internalOligo = nil }
                let product = try integer(try required(fields, "PRIMER_PAIR_\(index)_PRODUCT_SIZE"), "product size")
                pairs.append(Primer3Pair(id: UUID(), left: left, right: right, internalOligo: internalOligo, productSize: product))
            }
            return Primer3TemplateResult(resultID: expectedID, inputID: UUID(), title: "", sourceKind: "", sourceIndex: 0, sourceRecordID: "", templateSequence: "", alignmentToTemplate: nil, excludedRegions: [], pairs: pairs, error: fields["PRIMER_ERROR"], explanation: fields["PRIMER_PAIR_EXPLAIN"])
        }
    }

    private static func oligo(_ fields: [String: String], prefix: String, orientation: Primer3OligoOrientation) throws -> Primer3Oligo {
        let coordinate = try required(fields, prefix).split(separator: ",", omittingEmptySubsequences: false)
        guard coordinate.count == 2, let position = Int(coordinate[0]), let length = Int(coordinate[1]), position >= 0, length > 0 else { throw Primer3DesignError.malformedOutput("invalid \(prefix) coordinate") }
        let start = orientation == .forward ? position : position - length + 1
        guard start >= 0 else { throw Primer3DesignError.malformedOutput("negative \(prefix) start") }
        let sequence = try required(fields, "\(prefix)_SEQUENCE")
        guard sequence.count == length else { throw Primer3DesignError.malformedOutput("\(prefix) sequence length disagrees with coordinate") }
        return Primer3Oligo(id: UUID(), start: start, end: start + length, orientation: orientation, sequence: sequence, meltingTemperature: try finite(try required(fields, "\(prefix)_TM"), "Tm"), gcPercent: try finite(try required(fields, "\(prefix)_GC_PERCENT"), "GC"))
    }

    private static func required(_ fields: [String: String], _ key: String) throws -> String {
        guard let value = fields[key], !value.isEmpty else { throw Primer3DesignError.malformedOutput("missing \(key)") }
        return value
    }
    private static func integer(_ value: String, _ field: String) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else { throw Primer3DesignError.malformedOutput("invalid \(field)") }; return parsed
    }
    private static func finite(_ value: String, _ field: String) throws -> Double {
        guard let parsed = Double(value), parsed.isFinite else { throw Primer3DesignError.malformedOutput("invalid \(field)") }; return parsed
    }
}
