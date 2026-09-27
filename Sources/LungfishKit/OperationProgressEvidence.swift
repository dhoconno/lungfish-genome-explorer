import Foundation

/// An observation with an explicit meaning, independent of lifecycle and legacy stage weights.
public struct OperationProgressEvidence: Sendable, Equatable {
    public enum Scope: String, Sendable { case overall, stage }
    public enum Basis: String, Sendable { case measured, toolReported, estimated }

    public let phase: String
    public let scope: Scope
    public let basis: Basis
    public let completed: Double?
    public let total: Double?
    public let unit: String?
    public let fraction: Double?
    public let timestamp: Date

    /// Counters take precedence over `fraction` when both counters are supplied.
    /// Callers must only use `estimated` for an estimate with a justified denominator.
    public init(phase: String, scope: Scope, basis: Basis, completed: Double? = nil,
                total: Double? = nil, unit: String? = nil, fraction: Double? = nil,
                timestamp: Date = Date()) {
        self.phase = phase
        self.scope = scope
        self.basis = basis
        self.completed = completed
        self.total = total
        self.unit = unit
        self.fraction = fraction
        self.timestamp = timestamp
    }

    var validatedFraction: Double? {
        if let completed, let total {
            guard completed.isFinite, total.isFinite, total > 0,
                  completed >= 0, completed <= total else { return nil }
            return completed / total
        }
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return fraction
    }
}

/// A bounded rate window. A fraction alone never supplies evidence for a completion time.
struct OperationProgressRate: Sendable {
    private var samples: [OperationProgressEvidence] = []
    private static let freshness: TimeInterval = 30

    mutating func record(_ evidence: OperationProgressEvidence?) {
        guard let evidence, evidence.scope == .overall, evidence.basis == .measured,
              evidence.validatedFraction != nil, let completed = evidence.completed,
              evidence.total != nil, evidence.timestamp.timeIntervalSinceReferenceDate.isFinite else {
            samples.removeAll()
            return
        }
        if let previous = samples.last {
            let interval = evidence.timestamp.timeIntervalSince(previous.timestamp)
            if previous.phase != evidence.phase || previous.total != evidence.total || previous.unit != evidence.unit
                || completed < (previous.completed ?? 0) || interval < 0 || interval > Self.freshness {
                samples.removeAll()
            } else {
                // Repeated counters do not renew the last advancement time. Very frequent
                // reports accumulate before sampling, to avoid timer-resolution noise.
                guard completed > (previous.completed ?? 0), interval >= 0.5 else { return }
            }
        }
        samples.append(evidence)
        if samples.count > 8 { samples.removeFirst(samples.count - 8) }
    }

    func remainingTime(at date: Date) -> TimeInterval? {
        guard samples.count >= 3, let first = samples.first, let last = samples.last,
              let completed = last.completed, let total = last.total else { return nil }
        let age = date.timeIntervalSince(last.timestamp)
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard age >= 0, age <= Self.freshness, duration >= 2 else { return nil }
        let rates = zip(samples, samples.dropFirst()).map { earlier, later in
            ((later.completed ?? 0) - (earlier.completed ?? 0)) / later.timestamp.timeIntervalSince(earlier.timestamp)
        }
        guard let minimum = rates.min(), let maximum = rates.max(), minimum > 0,
              maximum.isFinite, maximum <= minimum * 2 else { return nil }
        let rate = (completed - (first.completed ?? 0)) / duration
        let remaining = (total - completed) / rate
        return remaining.isFinite && remaining >= 0 ? remaining : nil
    }
}
