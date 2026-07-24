import AppKit
import LungfishIO

/// A bounded, reference-relative summary of candidate differences from one extended CIGAR.
///
/// Markers represent CIGAR operations, not individual bases or BAM evidence rows. Exon labels
/// come only from the persisted closest-reference feature intervals.
@MainActor
final class GenotypeCandidateDifferenceTrackView: NSView {
    enum MismatchRegion: String, Equatable {
        case exonTwoOrThree
        case otherExon
        case intronOrNonExon
    }

    enum MarkerKind: Equatable {
        case mismatch(MismatchRegion)
        case insertion
        case deletion
    }

    struct Marker: Equatable {
        let kind: MarkerKind
        let referenceRange: Range<Int>
        let length: Int
    }

    struct Presentation: Equatable {
        let referenceLength: Int
        let markers: [Marker]
        let parsingIssue: String?
        let accessibilitySummary: String
    }

    private(set) var markers: [Marker] = []
    private(set) var parsingIssue: String?
    private(set) var configurationCount = 0
    private(set) var presentationApplicationCount = 0
    private(set) var currentPresentation = Presentation(
        referenceLength: 0,
        markers: [],
        parsingIssue: nil,
        accessibilitySummary: "No candidate difference data configured"
    )

    private var referenceLength = 0
    private static let maximumOperationCount = 10_000

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 58)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    func configure(
        referenceLength: Int,
        referenceStart: Int,
        cigar: String,
        features: [ONTMHCReferenceVisualizationFeature]
    ) {
        configurationCount += 1

        let presentation: Presentation
        do {
            let markers = try Self.parseMarkers(
                referenceLength: referenceLength,
                referenceStart: referenceStart,
                cigar: cigar,
                features: features
            )
            presentation = Presentation(
                referenceLength: max(0, referenceLength),
                markers: markers,
                parsingIssue: nil,
                accessibilitySummary: Self.accessibilitySummary(for: markers)
            )
        } catch let error as CIGARParseError {
            presentation = Presentation(
                referenceLength: max(0, referenceLength),
                markers: [],
                parsingIssue: error.message,
                accessibilitySummary: "Difference track unavailable: \(error.message)"
            )
        } catch {
            let issue = "The persisted extended CIGAR could not be parsed."
            presentation = Presentation(
                referenceLength: max(0, referenceLength),
                markers: [],
                parsingIssue: issue,
                accessibilitySummary: "Difference track unavailable: \(issue)"
            )
        }
        apply(presentation: presentation)
    }

    func apply(presentation: Presentation) {
        presentationApplicationCount += 1
        currentPresentation = presentation
        referenceLength = presentation.referenceLength
        markers = presentation.markers
        parsingIssue = presentation.parsingIssue
        setAccessibilityValue(presentation.accessibilitySummary)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard referenceLength > 0, bounds.width > 0 else { return }

        let trackRect = bounds.insetBy(dx: 8, dy: 9)
        let baselineY = trackRect.midY
        NSColor.separatorColor.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: trackRect.minX, y: baselineY))
        baseline.line(to: NSPoint(x: trackRect.maxX, y: baselineY))
        baseline.lineWidth = 1
        baseline.stroke()

        for marker in markers {
            draw(marker, in: trackRect, baselineY: baselineY)
        }
    }

    private func configureAccessibility() {
        setAccessibilityIdentifier("candidateDifferenceTrack")
        setAccessibilityRole(.valueIndicator)
        setAccessibilityLabel("Candidate differences relative to closest reference")
        setAccessibilityValue("No candidate difference data configured")
    }

    private func draw(_ marker: Marker, in trackRect: NSRect, baselineY: CGFloat) {
        let startX = xPosition(for: marker.referenceRange.lowerBound, in: trackRect)
        let endX = xPosition(for: marker.referenceRange.upperBound, in: trackRect)

        switch marker.kind {
        case .mismatch(let region):
            let color: NSColor
            switch region {
            case .exonTwoOrThree:
                color = .systemRed
            case .otherExon:
                color = .systemOrange
            case .intronOrNonExon:
                color = .systemPurple
            }
            color.setFill()
            let width = max(5, endX - startX)
            NSBezierPath(ovalIn: NSRect(
                x: min(trackRect.maxX - width, startX),
                y: baselineY - 3,
                width: width,
                height: 6
            )).fill()

        case .insertion:
            NSColor.systemTeal.setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: startX, y: baselineY + 9))
            path.line(to: NSPoint(x: startX - 4, y: baselineY + 2))
            path.line(to: NSPoint(x: startX + 4, y: baselineY + 2))
            path.close()
            path.fill()

        case .deletion:
            NSColor.systemBlue.setFill()
            let width = max(5, endX - startX)
            NSBezierPath(roundedRect: NSRect(
                x: min(trackRect.maxX - width, startX),
                y: baselineY - 3,
                width: width,
                height: 6
            ), xRadius: 2, yRadius: 2).fill()
        }
    }

    private func xPosition(for zeroBasedReferencePosition: Int, in rect: NSRect) -> CGFloat {
        let boundedPosition = min(max(0, zeroBasedReferencePosition), referenceLength)
        return rect.minX + (CGFloat(boundedPosition) / CGFloat(referenceLength)) * rect.width
    }

    private static func parseMarkers(
        referenceLength: Int,
        referenceStart: Int,
        cigar: String,
        features: [ONTMHCReferenceVisualizationFeature]
    ) throws -> [Marker] {
        guard referenceLength > 0 else {
            throw CIGARParseError("The closest-reference sequence is empty.")
        }
        guard referenceStart >= 1, referenceStart <= referenceLength else {
            throw CIGARParseError(
                "The 1-based reference start \(referenceStart) is outside 1–\(referenceLength)."
            )
        }
        guard !cigar.isEmpty else {
            throw CIGARParseError("The persisted extended CIGAR is empty.")
        }

        let bytes = Array(cigar.utf8)
        var index = 0
        var operationCount = 0
        var referencePosition = referenceStart - 1
        var parsedMarkers: [Marker] = []

        while index < bytes.count {
            guard bytes[index] >= 48, bytes[index] <= 57 else {
                throw CIGARParseError("The persisted extended CIGAR has invalid syntax.")
            }

            var length = 0
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                let digit = Int(bytes[index] - 48)
                let (multiplied, overflowedMultiply) = length.multipliedReportingOverflow(by: 10)
                let (nextLength, overflowedAdd) = multiplied.addingReportingOverflow(digit)
                guard !overflowedMultiply, !overflowedAdd else {
                    throw CIGARParseError("The persisted extended CIGAR length is too large.")
                }
                length = nextLength
                index += 1
            }

            guard length > 0, index < bytes.count else {
                throw CIGARParseError("The persisted extended CIGAR has invalid syntax.")
            }
            operationCount += 1
            guard operationCount <= maximumOperationCount else {
                throw CIGARParseError(
                    "The persisted extended CIGAR exceeds the \(maximumOperationCount)-operation display limit."
                )
            }

            let operation = bytes[index]
            index += 1
            switch operation {
            case 77, 61: // M, =
                try consumeReference(
                    length,
                    position: &referencePosition,
                    referenceLength: referenceLength
                )

            case 88: // X
                let start = referencePosition
                try consumeReference(
                    length,
                    position: &referencePosition,
                    referenceLength: referenceLength
                )
                let range = start..<referencePosition
                parsedMarkers.append(Marker(
                    kind: .mismatch(mismatchRegion(for: range, features: features)),
                    referenceRange: range,
                    length: length
                ))

            case 73: // I
                parsedMarkers.append(Marker(
                    kind: .insertion,
                    referenceRange: referencePosition..<referencePosition,
                    length: length
                ))

            case 68: // D
                let start = referencePosition
                try consumeReference(
                    length,
                    position: &referencePosition,
                    referenceLength: referenceLength
                )
                parsedMarkers.append(Marker(
                    kind: .deletion,
                    referenceRange: start..<referencePosition,
                    length: length
                ))

            case 78: // N (reference skip / long gap)
                try consumeReference(
                    length,
                    position: &referencePosition,
                    referenceLength: referenceLength
                )

            case 83, 72, 80: // S, H, P
                break

            default:
                throw CIGARParseError("The persisted extended CIGAR contains an unsupported operation.")
            }
        }
        return parsedMarkers
    }

    private static func consumeReference(
        _ length: Int,
        position: inout Int,
        referenceLength: Int
    ) throws {
        guard length <= referenceLength - position else {
            throw CIGARParseError("The persisted extended CIGAR extends beyond the closest reference.")
        }
        position += length
    }

    private static func mismatchRegion(
        for range: Range<Int>,
        features: [ONTMHCReferenceVisualizationFeature]
    ) -> MismatchRegion {
        let exons = features.filter {
            $0.type.caseInsensitiveCompare("exon") == .orderedSame
                && $0.start < $0.end
                && $0.interval.overlaps(range)
        }
        if exons.contains(where: { exonNumber(in: $0) == 2 || exonNumber(in: $0) == 3 }) {
            return .exonTwoOrThree
        }
        return exons.isEmpty ? .intronOrNonExon : .otherExon
    }

    private static func exonNumber(in feature: ONTMHCReferenceVisualizationFeature) -> Int? {
        for key in ["exon_number", "number"] {
            guard let actualKey = feature.qualifiers.keys.first(where: {
                $0.caseInsensitiveCompare(key) == .orderedSame
            }), let value = feature.qualifiers[actualKey]?.first else { continue }
            if let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return number
            }
        }
        return nil
    }

    private static func accessibilitySummary(for markers: [Marker]) -> String {
        let mismatchRegions = markers.compactMap { marker -> MismatchRegion? in
            guard case .mismatch(let region) = marker.kind else { return nil }
            return region
        }
        let exonTwoOrThree = mismatchRegions.filter { $0 == .exonTwoOrThree }.count
        let otherExon = mismatchRegions.filter { $0 == .otherExon }.count
        let intronOrNonExon = mismatchRegions.filter { $0 == .intronOrNonExon }.count
        let insertions = markers.filter { $0.kind == .insertion }.count
        let deletions = markers.filter { $0.kind == .deletion }.count

        guard !markers.isEmpty else {
            return "No extended-CIGAR X, insertion, or deletion markers"
        }
        return "\(markers.count) candidate difference markers: "
            + "\(mismatchRegions.count) substitutions "
            + "(\(exonTwoOrThree) exon 2/3, \(otherExon) other exon, "
            + "\(intronOrNonExon) intron/non-exon), "
            + "\(insertions) insertion\(insertions == 1 ? "" : "s"), "
            + "\(deletions) deletion\(deletions == 1 ? "" : "s")"
    }
}

private struct CIGARParseError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
