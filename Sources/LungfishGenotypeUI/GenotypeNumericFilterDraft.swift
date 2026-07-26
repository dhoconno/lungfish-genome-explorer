import Foundation
import LungfishKit
import Observation

@MainActor
protocol GenotypeNumericFilterScheduled: AnyObject {
    func cancel()
}

@MainActor
protocol GenotypeNumericFilterScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any GenotypeNumericFilterScheduled
}

@MainActor
final class GenotypeNumericFilterRunLoopScheduler:
    GenotypeNumericFilterScheduling {
    private final class Scheduled: GenotypeNumericFilterScheduled {
        var workItem: DispatchWorkItem?

        func cancel() {
            workItem?.cancel()
            workItem = nil
        }

    }

    init() {}

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any GenotypeNumericFilterScheduled {
        let scheduled = Scheduled()
        let workItem = DispatchWorkItem { [weak scheduled] in
            guard scheduled?.workItem?.isCancelled == false else { return }
            MainActor.assumeIsolated {
                action()
                scheduled?.workItem = nil
            }
        }
        scheduled.workItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
        return scheduled
    }
}

@MainActor
final class GenotypeNumericFilterCommitCoalescer {
    private let scheduler: any GenotypeNumericFilterScheduling
    private var scheduled: (any GenotypeNumericFilterScheduled)?
    private var generation: UInt64 = 0

    init(scheduler: any GenotypeNumericFilterScheduling) {
        self.scheduler = scheduler
    }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) {
        cancel()
        let expectedGeneration = generation
        scheduled = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.scheduled = nil
            action()
        }
    }

    func cancel() {
        generation &+= 1
        scheduled?.cancel()
        scheduled = nil
    }

    var hasPendingCommit: Bool {
        scheduled != nil
    }
}

struct GenotypeNumericFilterConfiguration: Equatable {
    enum ValueKind: Equatable {
        case integer
        case decimal(minimumFractionDigits: Int, maximumFractionDigits: Int)
    }

    let label: String
    let fieldAccessibilityIdentifier: String
    let stepperAccessibilityIdentifier: String
    let bounds: ClosedRange<Double>
    let step: Double
    let kind: ValueKind
    let valueSuffix: String?
    let boundsDescription: String
    let validationDescription: String
    let incrementActionDescription: String
    let decrementActionDescription: String

    static let matrixMinimumReads = GenotypeNumericFilterConfiguration(
        label: "Min reads",
        fieldAccessibilityIdentifier: "genotype-view-minimum-reads-field",
        stepperAccessibilityIdentifier: "genotype-view-minimum-reads-stepper",
        bounds: 0 ... 100_000,
        step: 1,
        kind: .integer,
        valueSuffix: nil,
        boundsDescription: "Minimum 0, maximum 100,000.",
        validationDescription: "Min reads must be a number from 0 through 100,000.",
        incrementActionDescription: "Increase Min reads by 1.",
        decrementActionDescription: "Decrease Min reads by 1."
    )

    static let matrixMinimumPercent = GenotypeNumericFilterConfiguration(
        label: "Min percent",
        fieldAccessibilityIdentifier: "genotype-view-minimum-percent-field",
        stepperAccessibilityIdentifier: "genotype-view-minimum-percent-stepper",
        bounds: 0 ... 100,
        step: 0.5,
        kind: .decimal(minimumFractionDigits: 1, maximumFractionDigits: 3),
        valueSuffix: "percent",
        boundsDescription: "Minimum 0, maximum 100 percent.",
        validationDescription: "Min percent must be a number from 0 through 100.",
        incrementActionDescription: "Increase Min percent by 0.5 percent.",
        decrementActionDescription: "Decrease Min percent by 0.5 percent."
    )
}

struct GenotypeNumericFilterAccessibilityState: Equatable {
    let label: String
    let value: String
    let bounds: String
    let incrementAction: String
    let decrementAction: String
    let validationDescription: String?
}

@Observable
@MainActor
final class GenotypeNumericFilterDraft {
    let configuration: GenotypeNumericFilterConfiguration
    private(set) var committedValue: Double
    private(set) var draftText: String
    private(set) var isInvalid = false

    @ObservationIgnored
    private let formatter: NumberFormatter
    @ObservationIgnored
    private let validationAnnouncementPoster:
        any AccessibilityAnnouncementPosting

    init(
        configuration: GenotypeNumericFilterConfiguration,
        committedValue: Double,
        locale: Locale,
        validationAnnouncementPoster: any AccessibilityAnnouncementPosting
    ) {
        let initialValue = configuration.bounds.clamped(committedValue)
        self.configuration = configuration
        self.committedValue = initialValue
        draftText = ""
        self.validationAnnouncementPoster = validationAnnouncementPoster
        formatter = Self.makeFormatter(
            configuration: configuration,
            locale: locale
        )
        draftText = formatter.string(
            from: NSNumber(value: initialValue)
        ) ?? "\(initialValue)"
    }

    var accessibility: GenotypeNumericFilterAccessibilityState {
        let value = configuration.valueSuffix.map {
            "\(draftText) \($0)"
        } ?? draftText
        return GenotypeNumericFilterAccessibilityState(
            label: configuration.label,
            value: value,
            bounds: configuration.boundsDescription,
            incrementAction: configuration.incrementActionDescription,
            decrementAction: configuration.decrementActionDescription,
            validationDescription: isInvalid
                ? configuration.validationDescription
                : nil
        )
    }

    func updateDraftText(_ value: String) {
        draftText = value
        let invalid = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedValue == nil
        if invalid && !isInvalid {
            validationAnnouncementPoster.post(
                configuration.validationDescription,
                priority: .high
            )
        }
        isInvalid = invalid
    }

    var parsedValue: Double? {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let number = formatter.number(from: trimmed)
        else {
            return nil
        }
        return number.doubleValue
    }

    var stepperValue: Double {
        configuration.bounds.clamped(parsedValue ?? committedValue)
    }

    @discardableResult
    func commitIfValid() -> Double? {
        guard let parsedValue else {
            if isInvalid {
                restore()
            }
            return nil
        }
        let value = configuration.bounds.clamped(parsedValue)
        applyCommittedValue(value)
        return value
    }

    func restore() {
        isInvalid = false
        draftText = formatted(committedValue)
    }

    func applyCommittedValue(_ value: Double) {
        committedValue = configuration.bounds.clamped(value)
        isInvalid = false
        draftText = formatted(committedValue)
    }

    private func formatted(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func makeFormatter(
        configuration: GenotypeNumericFilterConfiguration,
        locale: Locale
    ) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        formatter.usesGroupingSeparator = true
        switch configuration.kind {
        case .integer:
            formatter.allowsFloats = false
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        case .decimal(let minimum, let maximum):
            formatter.allowsFloats = true
            formatter.minimumFractionDigits = minimum
            formatter.maximumFractionDigits = maximum
        }
        return formatter
    }
}

private extension ClosedRange where Bound == Double {
    func clamped(_ value: Double) -> Double {
        Swift.max(lowerBound, Swift.min(upperBound, value))
    }
}
